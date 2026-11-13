package localtls

import (
	"crypto/tls"
	"crypto/x509"
	"net"
	"os"
	"testing"
	"time"
)

func TestPrivateEphemeralIdentity(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	files, err := Generate(dir)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := Client(files)
	if err != nil || len(cfg.Certificates) != 1 {
		t.Fatalf("invalid identity: %v", err)
	}
	info, err := os.Stat(files.Key)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("key is not private: %v", err)
	}
	if _, err := Generate(dir); err == nil {
		t.Fatal("identity overwrote existing files")
	}
	public := t.TempDir()
	if err := os.Chmod(public, 0755); err != nil {
		t.Fatal(err)
	}
	if _, err := Generate(public); err == nil {
		t.Fatal("accepted public directory")
	}
}

func TestMutualTLSRejectsAnonymousClient(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	files, err := Generate(dir)
	if err != nil {
		t.Fatal(err)
	}
	pem, err := os.ReadFile(files.CA)
	if err != nil {
		t.Fatal(err)
	}
	ca := x509.NewCertPool()
	ca.AppendCertsFromPEM(pem)
	identity, err := tls.LoadX509KeyPair(files.Cert, files.Key)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{identity}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: ca})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		done <- conn.(*tls.Conn).Handshake()
	}()
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", listener.Addr().String(), &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: ca, ServerName: "localhost"})
	if err == nil {
		_ = conn.Close()
	}
	if serverErr := <-done; serverErr == nil {
		t.Fatal("server accepted a client without a certificate")
	}
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		done <- conn.(*tls.Conn).Handshake()
	}()
	clientConfig, err := Client(files)
	if err != nil {
		t.Fatal(err)
	}
	conn, err = tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", listener.Addr().String(), clientConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if serverErr := <-done; serverErr != nil {
		t.Fatal(serverErr)
	}
}
