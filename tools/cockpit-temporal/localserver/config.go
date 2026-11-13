package localserver

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"

	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
	"go.temporal.io/server/common/config"
)

type Ports struct{ Frontend, FrontendMember, FrontendHTTP, History, HistoryMember, Matching, MatchingMember, Worker, WorkerMember int }

// Reserve distinct local ports while selecting them. The server reports a bind failure if another process takes one afterwards.
func PickPorts() (Ports, error) {
	listeners := make([]net.Listener, 0, 9)
	defer func() {
		for _, l := range listeners {
			_ = l.Close()
		}
	}()
	values := make([]int, 0, 9)
	for attempts := 0; len(listeners) < 9 && attempts < 300; attempts++ {
		// Temporal's PostgreSQL membership schema stores ports in a signed smallint.
		n, err := rand.Int(rand.Reader, big.NewInt(12000))
		if err != nil {
			return Ports{}, err
		}
		port := 20000 + int(n.Int64())
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			continue
		}
		listeners = append(listeners, listener)
		values = append(values, port)
	}
	if len(listeners) != 9 {
		return Ports{}, fmt.Errorf("could not reserve local Temporal ports")
	}
	return Ports{values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8]}, nil
}

// MakeConfig writes a private transient configuration; callers remove it after startup and never log its contents.
func MakeConfig(runtime, dbAddress, user, password string, cert localtls.Files, ports Ports) (*config.Config, error) {
	if err := PrivateDir(runtime); err != nil {
		return nil, err
	}
	q := strconv.Quote
	text := fmt.Sprintf(`
log:
  stdout: false
  level: error
persistence:
  defaultStore: primary
  visibilityStore: visibility
  numHistoryShards: 4
  datastores:
    primary:
      sql:
        pluginName: postgres12
        databaseName: temporal
        connectAddr: %s
        connectProtocol: tcp
        user: %s
        password: %s
        maxConns: 20
        maxIdleConns: 10
        maxConnLifetime: 1h
    visibility:
      sql:
        pluginName: postgres12
        databaseName: temporal_visibility
        connectAddr: %s
        connectProtocol: tcp
        user: %s
        password: %s
        maxConns: 5
        maxIdleConns: 2
        maxConnLifetime: 1h
global:
  membership:
    maxJoinDuration: 30s
    broadcastAddress: 127.0.0.1
  tls:
    internode:
      server:
        requireClientAuth: true
        certFile: %s
        keyFile: %s
        clientCaFiles: [%s]
      client:
        serverName: localhost
        rootCaFiles: [%s]
    frontend:
      server:
        requireClientAuth: true
        certFile: %s
        keyFile: %s
        clientCaFiles: [%s]
      client:
        serverName: localhost
        rootCaFiles: [%s]
services:
  frontend:
    rpc:
      grpcPort: %d
      membershipPort: %d
      bindOnLocalHost: true
      httpPort: %d
  history:
    rpc:
      grpcPort: %d
      membershipPort: %d
      bindOnLocalHost: true
  matching:
    rpc:
      grpcPort: %d
      membershipPort: %d
      bindOnLocalHost: true
  worker:
    rpc:
      grpcPort: %d
      membershipPort: %d
      bindOnLocalHost: true
clusterMetadata:
  enableGlobalNamespace: false
  failoverVersionIncrement: 10
  masterClusterName: active
  currentClusterName: active
  clusterInformation:
    active:
      enabled: true
      initialFailoverVersion: 1
      rpcName: frontend
      rpcAddress: %s
namespaceDefaults:
  archival:
    history:
      state: disabled
    visibility:
      state: disabled
`, q(dbAddress), q(user), q(password), q(dbAddress), q(user), q(password),
		q(cert.Cert), q(cert.Key), q(cert.CA), q(cert.CA), q(cert.Cert), q(cert.Key), q(cert.CA), q(cert.CA),
		ports.Frontend, ports.FrontendMember, ports.FrontendHTTP, ports.History, ports.HistoryMember,
		ports.Matching, ports.MatchingMember, ports.Worker, ports.WorkerMember, q(fmt.Sprintf("127.0.0.1:%d", ports.Frontend)))
	path := filepath.Join(runtime, "server-config.yaml")
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		return nil, err
	}
	defer os.Remove(path)
	return config.Load(config.WithConfigFile(path))
}
