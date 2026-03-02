package cmd

import (
	"fmt"
	"os/exec"
	"strconv"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
)

// autoDetectProtocol runs exactly once — when connect_protocol has never been
// set in ~/.sandcastle/config.yaml — and probes whether mosh is available both
// locally and on the sandbox server.  The result ("ssh" or "mosh") is persisted
// immediately so subsequent connects skip detection entirely.
//
// Callers should invoke this after waitForSSH and before cfg.LoadPreferences()
// so the saved value is picked up by the preference overlay.
func autoDetectProtocol(cfg *config.Config, info *api.ConnectInfo) {
	if cfg.Preferences.ConnectProtocol != "" {
		return // already decided (by user or a previous auto-detect)
	}

	fmt.Print("Auto-detecting protocol (first connect)... ")

	if _, err := exec.LookPath("mosh"); err != nil {
		fmt.Println("mosh not found locally → SSH")
		cfg.Preferences.ConnectProtocol = "ssh"
		_ = config.Save(cfg)
		return
	}

	if probeServerMosh(info.Host, info.Port, info.User) {
		fmt.Println("mosh available → using mosh by default")
		cfg.Preferences.ConnectProtocol = "mosh"
	} else {
		fmt.Println("mosh not on server → SSH")
		cfg.Preferences.ConnectProtocol = "ssh"
	}

	_ = config.Save(cfg)
}

// probeServerMosh SSHes to the sandbox and checks whether mosh is in PATH.
// Returns true only when the check exits 0 within 5 seconds.
func probeServerMosh(host string, port int, user string) bool {
	cmd := exec.Command("ssh",
		"-p", strconv.Itoa(port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=5",
		fmt.Sprintf("%s@%s", user, host),
		"command -v mosh",
	)
	return cmd.Run() == nil
}
