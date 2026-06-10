// outline-go-proxy: SOCKS5 proxy using the official Outline Go client.
// Uses the same outline-go-tun2socks library as Outline Windows/Android.
// Native support for Outline's TLS ClientHello prefix obfuscation.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/Jigsaw-Code/outline-go-tun2socks/outline"
	oss "github.com/Jigsaw-Code/outline-go-tun2socks/outline/shadowsocks"
)

type rawConfig struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Method   string `json:"method"`
	Password string `json:"password"`
	Prefix   string `json:"prefix"`
}

func main() {
	cfgPath := flag.String("config", "", "Path to Outline JSON config file")
	listenAddr := flag.String("listen", "127.0.0.1:1080", "SOCKS5 listen address")
	flag.Parse()

	if *cfgPath == "" {
		log.Fatal("--config is required")
	}

	data, err := os.ReadFile(*cfgPath)
	if err != nil {
		log.Fatal("Failed to read config:", err)
	}

	// Parse and validate
	var raw rawConfig
	if err := json.Unmarshal(data, &raw); err != nil {
		log.Fatal("Failed to parse config JSON:", err)
	}
	if raw.Host == "" {
		log.Fatal("Config missing 'host' field")
	}

	client, err := oss.NewClientFromJSON(string(data))
	if err != nil {
		log.Fatal("Failed to create Outline client:", err)
	}

	// Connectivity test
	conn, err := (*outline.Client)(client).Dial(context.Background(), "example.com:80")
	if err != nil {
		log.Fatal("Connectivity test failed:", err)
	}
	conn.Close()

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatal(err)
	}
	defer ln.Close()

	log.Printf("Outline Go proxy listening on %s → %s:%d (%s)",
		*listenAddr, raw.Host, raw.Port, raw.Method)

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sigCh; ln.Close() }()

	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go handleConn(conn, client)
	}
}

func handleConn(local net.Conn, client *oss.Client) {
	defer local.Close()

	buf := make([]byte, 4096)

	// SOCKS5 handshake: client sends [ver, nmethods, method_1, ..., method_n]
	if _, err := io.ReadFull(local, buf[:2]); err != nil {
		return
	}
	if buf[0] != 0x05 {
		return
	}
	nmethods := int(buf[1])
	if nmethods > 0 {
		if _, err := io.ReadFull(local, buf[:nmethods]); err != nil {
			return
		}
	}
	local.Write([]byte{0x05, 0x00}) // no auth

	// SOCKS5 CONNECT request
	if _, err := io.ReadFull(local, buf[:4]); err != nil {
		return
	}
	if buf[1] != 0x01 {
		return
	}

	var target string
	switch buf[3] {
	case 0x01: // IPv4
		if _, err := io.ReadFull(local, buf[:4]); err != nil {
			return
		}
		target = net.IP(buf[:4]).String()
	case 0x03: // Domain name
		if _, err := io.ReadFull(local, buf[:1]); err != nil {
			return
		}
		domainLen := int(buf[0])
		if _, err := io.ReadFull(local, buf[:domainLen]); err != nil {
			return
		}
		target = string(buf[:domainLen])
	default:
		return
	}

	if _, err := io.ReadFull(local, buf[:2]); err != nil {
		return
	}
	port := int(buf[0])<<8 | int(buf[1])
	targetAddr := net.JoinHostPort(target, fmt.Sprint(port))

	// Dial through Outline Shadowsocks
	remote, err := (*outline.Client)(client).Dial(context.Background(), targetAddr)
	if err != nil {
		local.Write([]byte{0x05, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})
		return
	}
	defer remote.Close()

	local.Write([]byte{0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00})

	// Relay
	done := make(chan struct{}, 2)
	go func() { io.Copy(remote, local); done <- struct{}{} }()
	go func() { io.Copy(local, remote); done <- struct{}{} }()
	<-done
	<-done
}
