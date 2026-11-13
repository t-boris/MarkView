package localserver

import (
	"fmt"

	"go.temporal.io/server/common/config"
	_ "go.temporal.io/server/common/persistence/sql/sqlplugin/postgresql"
	commonschema "go.temporal.io/server/tools/common/schema"
	temporalsql "go.temporal.io/server/tools/sql"
)

// Migrate uses Temporal's embedded, versioned schema; it never drops an existing database.
func Migrate(address, user, password string) error {
	logger := quietLogger{}
	database := func(name string) *config.SQL {
		return &config.SQL{PluginName: "postgres12", DatabaseName: name, ConnectAddr: address, ConnectProtocol: "tcp", User: user, Password: password}
	}
	for _, item := range []struct{ name, schema string }{{"temporal", "postgresql/v12/temporal"}, {"temporal_visibility", "postgresql/v12/visibility"}} {
		cfg := database(item.name)
		if err := temporalsql.DoCreateDatabase(cfg, "postgres", logger); err != nil {
			return fmt.Errorf("create Temporal database: %w", err)
		}
		conn, err := temporalsql.NewConnection(database(item.name), logger)
		if err != nil {
			return fmt.Errorf("connect Temporal database: %w", err)
		}
		err = commonschema.NewSetupSchemaTask(conn, &commonschema.SetupConfig{InitialVersion: "0.0"}, logger).Run()
		if err == nil {
			err = commonschema.NewUpdateSchemaTask(conn, &commonschema.UpdateConfig{DBName: item.name, SchemaName: item.schema}, logger).Run()
		}
		conn.Close()
		if err != nil {
			return fmt.Errorf("migrate Temporal database: %w", err)
		}
	}
	return nil
}
