package localserver

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"time"

	postgres "github.com/fergusstrange/embedded-postgres/v2"
	cockpit "github.com/t-boris/MarkView/cockpit-temporal"
	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
	"go.temporal.io/api/serviceerror"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/temporal"
	"google.golang.org/protobuf/types/known/durationpb"
)

type Options struct {
	Runtime            string
	State              string
	PostgresBinaries   string
	PostgresSupervisor string
	Logger             log.Logger
}
type Endpoint struct {
	Address string         `json:"address"`
	TLS     localtls.Files `json:"tls"`
}
type Server struct {
	temporal temporal.Server
	postgres *postgres.EmbeddedPostgres
	Endpoint Endpoint
}

// Start requires packaged PostgreSQL binaries and supervisor; it never downloads software or deletes state.
func Start(ctx context.Context, options Options) (_ *Server, resultErr error) {
	if err := PrivateDir(options.Runtime); err != nil {
		return nil, err
	}
	if err := PrivateDir(options.State); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(options.PostgresBinaries) || !filepath.IsAbs(options.PostgresSupervisor) {
		return nil, errors.New("packaged PostgreSQL paths are required")
	}
	password, err := Password(options.State)
	if err != nil {
		return nil, err
	}
	certs, err := localtls.Generate(options.Runtime)
	if err != nil {
		return nil, err
	}
	defer func() {
		if resultErr != nil {
			removeTLS(certs)
		}
	}()
	pg := postgres.NewDatabase(postgres.DefaultConfig().Version(postgres.V16).Port(0).Username("markview").Password(password).
		Storage(postgres.Storage{DataDir: filepath.Join(options.State, "postgres"), WorkDir: options.Runtime}).
		Provider(postgres.LocalProvider(options.PostgresBinaries)).Supervisor(options.PostgresSupervisor).Logger(io.Discard))
	if err := pg.StartContext(ctx); err != nil {
		return nil, fmt.Errorf("local PostgreSQL could not start: %w", err)
	}
	defer func() {
		if resultErr != nil {
			_ = pg.Close()
		}
	}()
	dbAddress := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(pg.GetPort())))
	if err := Migrate(dbAddress, "markview", password); err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	ports, err := PickPorts()
	if err != nil {
		return nil, err
	}
	cfg, err := MakeConfig(options.Runtime, dbAddress, "markview", password, certs, ports)
	if err != nil {
		return nil, err
	}
	logger := options.Logger
	if logger == nil {
		logger = quietLogger{}
	}
	server, err := temporal.NewServer(temporal.ForServices(temporal.DefaultServices), temporal.WithConfig(cfg), temporal.WithLogger(logger))
	if err != nil {
		return nil, fmt.Errorf("local Temporal configuration: %w", err)
	}
	if err := server.Start(); err != nil {
		return nil, fmt.Errorf("local Temporal could not start: %w", err)
	}
	defer func() {
		if resultErr != nil {
			_ = server.Stop()
		}
	}()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	endpoint := Endpoint{Address: net.JoinHostPort("127.0.0.1", strconv.Itoa(ports.Frontend)), TLS: certs}
	tlsConfig, err := localtls.Client(certs)
	if err != nil {
		return nil, err
	}
	dialCtx, dialCancel := context.WithTimeout(ctx, 30*time.Second)
	defer dialCancel()
	c, err := client.DialContext(dialCtx, client.Options{HostPort: endpoint.Address, Logger: cockpit.QuietSDKLogger{}, ConnectionOptions: client.ConnectionOptions{TLS: tlsConfig}})
	if err != nil {
		return nil, fmt.Errorf("connect local Temporal: %w", err)
	}
	defer c.Close()
	registerCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	_, err = c.WorkflowService().RegisterNamespace(registerCtx, &workflowservice.RegisterNamespaceRequest{Namespace: "default", WorkflowExecutionRetentionPeriod: durationpb.New(30 * 24 * time.Hour)})
	var exists *serviceerror.NamespaceAlreadyExists
	if err != nil && !errors.As(err, &exists) {
		return nil, fmt.Errorf("prepare local Temporal namespace: %w", err)
	}
	return &Server{temporal: server, postgres: pg, Endpoint: endpoint}, nil
}

func (s *Server) Close() error {
	err := errors.Join(s.temporal.Stop(), s.postgres.Close())
	removeTLS(s.Endpoint.TLS)
	return err
}

func removeTLS(files localtls.Files) {
	for _, path := range []string{files.Key, files.Cert, files.CA} {
		_ = os.Remove(path)
	}
}
