module ActiveRecord # :nodoc:
  module ConnectionAdapters # :nodoc:
    # Patched version:  3.1.3
    # Patched methods::
    #   * indexes
    class PostgreSQLAdapter
      # Regex to find columns used in index statements
      INDEX_COLUMN_EXPRESSION = /ON [\w\.]+(?: USING \w+ )?\((.+)\)/
      # Regex to find where clause in index statements
      INDEX_WHERE_EXPRESSION = /WHERE (.+)$/

      # Taken from https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_index.h#L75
      # Values are in reverse order
      INDOPTION_DESC        = 1
      # NULLs are first instead of last
      INDOPTION_NULLS_FIRST = 2

      # Returns the list of all tables in the schema search path or a specified schema.
      #
      # == Patch:
      # If current user is not `postgres` original method return all tables from all schemas
      # without schema prefix. This disables such behavior by querying only default schema.
      # Tables with schemas will be queried later.
      #
      def tables(name = nil)
        query(<<-SQL, 'SCHEMA').map { |row| row[0] }
            SELECT tablename
            FROM pg_tables
            WHERE schemaname = ANY (ARRAY['public'])
        SQL
      end

      # Checks if index exists for given table.
      #
      # == Patch:
      # Search using provided schema if table_name includes schema name.
      #
      def index_name_exists?(table_name, index_name, default)
        postgre_sql_name = PostgreSQL::Utils.extract_schema_qualified_name(table_name)
        schema, table = postgre_sql_name.schema, postgre_sql_name.identifier
        schemas = schema ? "ARRAY['#{schema}']" : 'current_schemas(false)'

        exec_query(<<-SQL, 'SCHEMA').rows.first[0].to_i > 0
          SELECT COUNT(*)
          FROM pg_class t
          INNER JOIN pg_index d ON t.oid = d.indrelid
          INNER JOIN pg_class i ON d.indexrelid = i.oid
          WHERE i.relkind = 'i'
            AND i.relname = '#{index_name}'
            AND t.relname = '#{table}'
            AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname = ANY (#{schemas}) )
        SQL
      end

      # Returns an array of indexes for the given table.
      #
      # == Patch 1 reason:
      # Since {ActiveRecord::SchemaDumper#tables} is patched to process tables
      # with a schema prefix, the {#indexes} method receives table_name as
      # "<schema>.<table>". This patch allows it to handle table names with
      # a schema prefix.
      #
      # == Patch 1:
      # Search using provided schema if table_name includes schema name.
      #
      # == Patch 2 reason:
      # {ActiveRecord::ConnectionAdapters::PostgreSQLAdapter#indexes} is patched
      # to support partial indexes using :where clause.
      #
      # == Patch 2:
      # Search the postgres indexdef for the where clause and pass the output to
      # the custom {PgSaurus::ConnectionAdapters::IndexDefinition}
      #
      def indexes(table_name, name = nil)
        postgre_sql_name = PostgreSQL::Utils.extract_schema_qualified_name(table_name)
        schema, table = postgre_sql_name.schema, postgre_sql_name.identifier
        schemas = schema ? "ARRAY['#{schema}']" : 'current_schemas(false)'

        result = query(<<-SQL, name)
          SELECT distinct i.relname,
                          d.indisunique,
                          d.indkey,
                          pg_get_indexdef(d.indexrelid),
                          t.oid,
                          am.amname,
                          d.indclass,
                          d.indoption
          FROM pg_class t
          INNER JOIN pg_index d ON t.oid = d.indrelid
          INNER JOIN pg_class i ON d.indexrelid = i.oid
          INNER JOIN pg_am    am ON i.relam = am.oid
          WHERE i.relkind = 'i'
            AND d.indisprimary = 'f'
            AND t.relname = '#{table}'
            AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname = ANY (#{schemas}) )
         ORDER BY i.relname
        SQL

        result.map do |row|
          index = {
            :name          => row[0],
            :unique        => row[1] == 't',
            :keys          => row[2].split(" "),
            :definition    => row[3],
            :id            => row[4],
            :access_method => row[5], 
            :operators     => row[6].split(" "),
            :options       => row[7].split(" ").map(&:to_i)
          }

          column_names = find_column_names(table_name, index)

          operator_names = find_operator_names(column_names, index)

          unless column_names.empty?
            where   = find_where_statement(index)
            lengths = find_lengths(index)

            PgSaurus::ConnectionAdapters::IndexDefinition.new(
              table_name,
              index[:name],
              index[:unique],
              column_names,
              lengths,
              where,
              index[:access_method],
              operator_names
            )
          end
        end.compact
      end

      # Find column names from index attributes. If the columns are virtual (i.e.
      # this is an expression index) then it will try to return the functions
      # that represent each column.
      #
      # @param [String] table_name the name of the table, possibly schema-qualified
      # @param [Hash] index index attributes
      # @return [Array]
      def find_column_names(table_name, index)
        columns = Hash[query(<<-SQL, "Columns for index #{index[:name]} on #{table_name}")]
          SELECT a.attnum, a.attname
          FROM pg_attribute a
          WHERE a.attrelid = #{index[:id]}
          AND a.attnum IN (#{index[:keys].join(",")})
        SQL

        column_names = columns.values_at(*index[:keys]).compact

        if column_names.empty?
          definition = index[:definition].sub(INDEX_WHERE_EXPRESSION, '')
          if column_expression = definition.match(INDEX_COLUMN_EXPRESSION)[1]
            column_names = split_expression(column_expression).map do |functional_name|
              remove_type(functional_name)
            end
          end
        else
          # In case if column_names if not empty it contains list of column name taken from pg_attribute table.
          # So we need to check indoption column and add DESC and NULLS LAST based on its value.
          # https://stackoverflow.com/questions/18121103/how-to-get-the-index-column-orderasc-desc-nulls-first-from-postgresql/18128457#18128457
          column_names = column_names.map.with_index do |column_name, column_index|
            option = index[:options][column_index]

            if option != 0
              column_name << " DESC" if option & INDOPTION_DESC > 0

              if option & INDOPTION_NULLS_FIRST > 0
                column_name << " NULLS FIRST"
              else
                column_name << " NULLS LAST"
              end
            end

            column_name
          end
        end

        column_names
      end

      # Find non-default operator class names for columns from index.
      #
      # @param column_names [Array] List of columns from index.
      # @param index [Hash] index index attributes
      # @return [Hash]
      def find_operator_names(column_names, index)
        column_names.each_with_index.inject({}) do |class_names, (column_name, column_index)|
          result = query(<<-SQL, "Classes for columns for index #{index[:name]} for column #{column_name}")
            SELECT op.opcname, op.opcdefault
            FROM pg_opclass op
            WHERE op.oid = #{index[:operators][column_index]};
          SQL

          row = result.first

          if row && row[1] == "f"
            class_names[column_name] = row[0]
          end

          class_names
        end
      end

      # Splits only on commas outside of parens
      def split_expression(expression)
        result = []
        parens = 0
        buffer = ""

        expression.chars do |char|
          case char
          when ','
            if parens == 0
              result.push(buffer)
              buffer = ""
              next
            end
          when '('
            parens += 1
          when ')'
            parens -= 1
          end

          buffer << char
        end

        result << buffer unless buffer.empty?
        result
      end

      # Find where statement from index definition
      #
      # @param [Hash] index index attributes
      # @return [String] where statement
      def find_where_statement(index)
        index[:definition].scan(INDEX_WHERE_EXPRESSION).flatten[0]
      end

      # Find length of index
      # TODO Update lengths once we merge in ActiveRecord code that supports it. -dresselm 20120305
      #
      # @param [Hash] index index attributes
      # @return [Array]
      def find_lengths(index)
        []
      end

      # Remove type specification from stored Postgres index definitions
      #
      # @param [String] column_with_type the name of the column with type
      # @return [String]
      #
      # @example
      #   remove_type("((col)::text")
      #   => "col"
      def remove_type(column_with_type)
        column_with_type.sub(/\((\w+)\)::\w+/, '\1')
      end
    end
  end
end
