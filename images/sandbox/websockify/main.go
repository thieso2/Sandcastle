// websockify: minimal WebSocket → TCP proxy for VNC.
// Accepts WebSocket connections and tunnels binary frames to a TCP target.
// Usage: websockify -addr :6080 -target localhost:5900 -url /websockify
package main

import (
	"flag"
	"log"
	"net"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	// Allow connections from any origin (auth is handled upstream by Traefik forwardAuth).
	CheckOrigin: func(r *http.Request) bool { return true },
}

func proxy(ws *websocket.Conn, target string) {
	conn, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("dial %s: %v", target, err)
		return
	}
	defer conn.Close()

	done := make(chan struct{}, 1)

	// VNC → WebSocket (server speaks first with RFB banner)
	go func() {
		defer func() { done <- struct{}{} }()
		buf := make([]byte, 65536)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	}()

	// WebSocket → VNC
	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			break
		}
		if _, err := conn.Write(msg); err != nil {
			break
		}
	}
	<-done
}

func main() {
	addr := flag.String("addr", ":6080", "listen address")
	target := flag.String("target", "localhost:5900", "TCP target address (Xvnc)")
	path := flag.String("url", "/websockify", "WebSocket URL path")
	flag.Parse()

	http.HandleFunc(*path, func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("websocket upgrade: %v", err)
			return
		}
		defer ws.Close()
		proxy(ws, *target)
	})

	log.Printf("websockify: listening on %s, proxying %s → %s", *addr, *path, *target)
	log.Fatal(http.ListenAndServe(*addr, nil))
}
