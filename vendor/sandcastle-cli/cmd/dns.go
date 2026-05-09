package cmd

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/sandcastle/cli/internal/dnsproxy"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

const (
	resolverMarker  = "# Managed by sandcastle dns"
	resolverVersion = "2"
	hostsBeginMark  = "# BEGIN sandcastle-dns"
	hostsEndMark    = "# END sandcastle-dns"
	hostsTargetPath = "/etc/hosts"
)

var (
	dnsInstallSearch   bool
	dnsInstallForce    bool
	dnsUninstallSuffix string
	dnsSearchProject   string
	dnsSearchService   string
	dnsSearchAll       bool
	serverRemoveForce  bool
)

var resolverRoot = "/etc/resolver"

type dnsState struct {
	Version int                                       `yaml:"version,omitempty"`
	Search  map[string]map[string]managedSearchDomain `yaml:"search,omitempty"`
	Proxies map[string]dnsProxyState                  `yaml:"proxies,omitempty"`
}

type managedSearchDomain struct {
	AddedBySandcastle bool `yaml:"added_by_sandcastle"`
}

type dnsProxyState struct {
	Suffix             string `yaml:"suffix"`
	RawSuffix          string `yaml:"raw_suffix,omitempty"`
	LocalAddress       string `yaml:"local_address"`
	UpstreamAddress    string `yaml:"upstream_address"`
	LaunchdLabel       string `yaml:"launchd_label"`
	PlistPath          string `yaml:"plist_path"`
	StdoutLogPath      string `yaml:"stdout_log_path"`
	StderrLogPath      string `yaml:"stderr_log_path"`
	ServerAlias        string `yaml:"server_alias,omitempty"`
	ServerURL          string `yaml:"server_url,omitempty"`
	ResolverBackupPath string `yaml:"resolver_backup_path,omitempty"`
}

type resolverInfo struct {
	State       string
	Managed     bool
	Legacy      bool
	Suffix      string
	Domain      string
	Nameserver  string
	Port        int
	ServerAlias string
	ServerURL   string
	Upstream    string
	BackupPath  string
}

type launchdStatus struct {
	Loaded  bool
	Running bool
	Raw     string
}

func init() {
	rootCmd.AddCommand(dnsCmd)
	dnsCmd.AddCommand(dnsStatusCmd)
	dnsCmd.AddCommand(dnsInstallCmd)
	dnsCmd.AddCommand(dnsUninstallCmd)
	dnsCmd.AddCommand(dnsProxyCmd)
	dnsCmd.AddCommand(dnsSearchCmd)
	dnsCmd.AddCommand(dnsHostsCmd)
	dnsCmd.AddCommand(dnsAliasCmd)

	dnsHostsCmd.AddCommand(dnsHostsSyncCmd)
	dnsHostsCmd.AddCommand(dnsHostsClearCmd)
	dnsHostsCmd.AddCommand(dnsHostsStatusCmd)

	dnsAliasCmd.AddCommand(dnsAliasAddCmd)
	dnsAliasCmd.AddCommand(dnsAliasRemoveCmd)
	dnsAliasCmd.AddCommand(dnsAliasListCmd)

	dnsInstallCmd.Flags().BoolVar(&dnsInstallSearch, "search", false, "Also add the instance suffix to the macOS DNS search path")
	dnsInstallCmd.Flags().BoolVar(&dnsInstallForce, "force", false, "Back up and replace an existing unmanaged resolver file")
	dnsUninstallCmd.Flags().StringVar(&dnsUninstallSuffix, "suffix", "", "DNS suffix to uninstall without contacting the server")

	dnsSearchCmd.AddCommand(dnsSearchStatusCmd)
	dnsSearchCmd.AddCommand(dnsSearchAddCmd)
	dnsSearchCmd.AddCommand(dnsSearchRemoveCmd)

	for _, c := range []*cobra.Command{dnsSearchAddCmd, dnsSearchRemoveCmd} {
		c.Flags().StringVar(&dnsSearchProject, "project", "", "Manage project search suffix (<project>.<instance>)")
		c.Flags().StringVar(&dnsSearchService, "service", "", "macOS network service to update")
		c.Flags().BoolVar(&dnsSearchAll, "all-enabled", false, "Update all enabled macOS network services")
	}
	dnsSearchStatusCmd.Flags().StringVar(&dnsSearchService, "service", "", "macOS network service to inspect")
	dnsSearchStatusCmd.Flags().BoolVar(&dnsSearchAll, "all-enabled", false, "Inspect all enabled macOS network services")

	dnsProxyCmd.AddCommand(dnsProxyServeCmd)
	dnsProxyServeCmd.Flags().StringVar(&dnsProxyListen, "listen", "", "local listen address")
	dnsProxyServeCmd.Flags().StringVar(&dnsProxyUpstream, "upstream", "", "upstream DNS address")
	dnsProxyServeCmd.Flags().BoolVar(&dnsProxyVerbose, "verbose", false, "log each query")
	dnsProxyCmd.Hidden = true
	dnsProxyServeCmd.Hidden = true
}

var dnsCmd = &cobra.Command{
	Use:   "dns",
	Short: "Manage Sandcastle DNS on this client",
}

var (
	dnsProxyListen   string
	dnsProxyUpstream string
	dnsProxyVerbose  bool
)

var dnsProxyCmd = &cobra.Command{
	Use:   "proxy",
	Short: "Internal DNS proxy commands",
}

var dnsProxyServeCmd = &cobra.Command{
	Use:   "serve",
	Short: "Run the local DNS proxy",
	RunE: func(cmd *cobra.Command, args []string) error {
		if dnsProxyListen == "" {
			return fmt.Errorf("--listen is required")
		}
		if dnsProxyUpstream == "" {
			return fmt.Errorf("--upstream is required")
		}
		return dnsproxy.Serve(cmd.Context(), dnsproxy.Config{
			Listen:   dnsProxyListen,
			Upstream: dnsProxyUpstream,
			Verbose:  dnsProxyVerbose,
			Log:      os.Stderr,
		})
	},
}

var dnsStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Sandcastle DNS status",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		var status *api.DNSStatus
		if err == nil {
			printServer(client)
			status, err = client.DNSStatus()
		}

		w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
		if status != nil && err == nil {
			fmt.Fprintf(w, "Suffix:\t%s\n", valueOrDash(status.Suffix))
			fmt.Fprintf(w, "Resolver IP:\t%s\n", valueOrDash(status.ResolverIP))
			fmt.Fprintf(w, "Tailscale IP:\t%s\n", valueOrDash(status.TailscaleIP))
			fmt.Fprintf(w, "Resolver running:\t%t\n", status.ResolverRunning)
			fmt.Fprintf(w, "Network:\t%s\n", valueOrDash(status.Network))
			fmt.Fprintf(w, "Hosts file:\t%s\n", valueOrDash(status.HostsPath))
		} else {
			fmt.Fprintf(w, "Server:\toffline (%v)\n", err)
		}
		if runtime.GOOS == "darwin" {
			if err := printLocalDNSStatus(w, status); err != nil {
				return err
			}
		}
		w.Flush()

		if status != nil && len(status.Records) > 0 {
			fmt.Println()
			w = tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "NAME\tIP")
			for _, r := range status.Records {
				fmt.Fprintf(w, "%s\t%s\n", r.Name, r.IP)
			}
			w.Flush()
		}

		if status != nil && len(status.Skipped) > 0 {
			fmt.Println()
			w = tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "SKIPPED\tREASON")
			for _, s := range status.Skipped {
				fmt.Fprintf(w, "%s\t%s\n", s.Name, s.Reason)
			}
			w.Flush()
		}
		return nil
	},
}

var dnsInstallCmd = &cobra.Command{
	Use:   "install",
	Short: "Install macOS local proxy resolver configuration for Sandcastle DNS",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := requireDarwin(); err != nil {
			return err
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		status, err := client.DNSReconcile()
		if err != nil {
			return err
		}
		if status.Suffix == "" {
			return fmt.Errorf("server did not return a DNS suffix")
		}
		if status.ResolverIP == "" {
			return fmt.Errorf("DNS resolver IP is not available; enable Tailscale and approve subnet routes first")
		}

		if err := installProxyResolver(status, client, dnsInstallForce); err != nil {
			return err
		}
		fmt.Printf("Installed /etc/resolver/%s through local DNS proxy\n", normalizeSuffix(status.Suffix))

		if dnsInstallSearch {
			if err := addSearchDomain(status.Suffix); err != nil {
				return err
			}
			fmt.Printf("Added search domain %s\n", status.Suffix)
		}
		return nil
	},
}

var dnsUninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "Remove Sandcastle macOS resolver configuration",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := requireDarwin(); err != nil {
			return err
		}

		suffix := dnsUninstallSuffix
		if suffix == "" {
			if client, err := api.NewClient(); err == nil {
				if status, err := client.DNSStatus(); err == nil {
					suffix = status.Suffix
				}
			}
		}
		if err := uninstallProxyResolver(suffix); err != nil {
			return err
		}
		fmt.Printf("Removed Sandcastle DNS resolver%s\n", suffixMessage(suffix))
		return nil
	},
}

var dnsSearchCmd = &cobra.Command{
	Use:   "search",
	Short: "Manage macOS DNS search domains for Sandcastle",
}

var dnsSearchStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show macOS DNS search domains",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := requireDarwin(); err != nil {
			return err
		}

		services, err := targetServices()
		if err != nil {
			return err
		}
		w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "SERVICE\tSEARCH DOMAINS")
		for _, service := range services {
			domains, err := getSearchDomains(service)
			if err != nil {
				return err
			}
			fmt.Fprintf(w, "%s\t%s\n", service, displayDomains(domains))
		}
		return w.Flush()
	},
}

var dnsSearchAddCmd = &cobra.Command{
	Use:   "add",
	Short: "Add Sandcastle DNS suffix to the macOS search path",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := requireDarwin(); err != nil {
			return err
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		status, err := client.DNSStatus()
		if err != nil {
			return err
		}
		if status.Suffix == "" {
			return fmt.Errorf("server did not return a DNS suffix")
		}
		domain, err := searchDomain(status.Suffix)
		if err != nil {
			return err
		}
		if err := addSearchDomain(domain); err != nil {
			return err
		}
		fmt.Printf("Added search domain %s\n", domain)
		return nil
	},
}

var dnsSearchRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove Sandcastle-managed DNS suffix from the macOS search path",
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := requireDarwin(); err != nil {
			return err
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		status, err := client.DNSStatus()
		if err != nil {
			return err
		}
		if status.Suffix == "" {
			return fmt.Errorf("server did not return a DNS suffix")
		}
		domain, err := searchDomain(status.Suffix)
		if err != nil {
			return err
		}
		if err := removeSearchDomain(domain); err != nil {
			return err
		}
		fmt.Printf("Removed Sandcastle-managed search domain %s\n", domain)
		return nil
	},
}

var dnsHostsCmd = &cobra.Command{
	Use:   "hosts",
	Short: "Manage /etc/hosts entries for Sandcastle sandboxes",
	Long: "Write a managed block of sandbox name→IP mappings into /etc/hosts.\n" +
		"This is a fallback for debugging or non-macOS clients; macOS resolver\n" +
		"install uses a local DNS proxy by default.",
}

var dnsHostsSyncCmd = &cobra.Command{
	Use:   "sync",
	Short: "Write the current sandbox list into /etc/hosts",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		count, err := syncHostsFromServer(client)
		if err != nil {
			return err
		}
		if count == 0 {
			fmt.Println("No DNS records returned by server; cleared managed block.")
		} else {
			fmt.Printf("Wrote %d entries to %s\n", count, hostsTargetPath)
		}
		return nil
	},
}

// syncHostsFromServer reads DNS state from the server and rewrites the
// managed block in /etc/hosts. Returns the number of records written.
func syncHostsFromServer(client *api.Client) (int, error) {
	status, err := client.DNSStatus()
	if err != nil {
		return 0, err
	}
	if len(status.Records) == 0 {
		if err := clearHostsBlock(); err != nil {
			return 0, err
		}
		return 0, nil
	}
	if err := writeHostsBlock(status.Records); err != nil {
		return 0, err
	}
	return len(status.Records), nil
}

// autoSyncHostsBestEffort refreshes /etc/hosts after a state-changing CLI
// command. It silently no-ops when /etc/hosts has no Sandcastle-managed
// block — opt-in via `sandcastle dns hosts sync`. Errors are reported to
// stderr but do not fail the parent command.
func autoSyncHostsBestEffort(client *api.Client) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		return
	}
	block, err := readHostsBlock()
	if err != nil || block == "" {
		return
	}
	if _, err := syncHostsFromServer(client); err != nil {
		fmt.Fprintf(os.Stderr, "warning: auto-sync /etc/hosts failed: %v\n", err)
	}
}

var dnsHostsClearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Remove the Sandcastle-managed block from /etc/hosts",
	RunE: func(cmd *cobra.Command, args []string) error {
		return clearHostsBlock()
	},
}

var dnsHostsStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show the Sandcastle-managed block in /etc/hosts",
	RunE: func(cmd *cobra.Command, args []string) error {
		block, err := readHostsBlock()
		if err != nil {
			return err
		}
		if block == "" {
			fmt.Printf("No Sandcastle-managed block in %s\n", hostsTargetPath)
			return nil
		}
		fmt.Print(block)
		return nil
	},
}

var dnsAliasCmd = &cobra.Command{
	Use:   "alias",
	Short: "Manage extra hostnames (aliases) for a sandbox",
	Long: `Add additional hostnames that resolve to a sandbox.

Two kinds of alias:
  sub  <value> <sandbox>   — value is prefixed onto the sandbox's FQDN.
                             e.g. "admin" on sandbox "dev" → admin.dev.<project>.<host>
  fqdn <value> <sandbox>   — value is used verbatim, e.g. www.example.com.

Aliases land in the server's DNS records and in /etc/hosts (after
` + "`sandcastle dns hosts sync`" + `). FQDN aliases are also added to the
mkcert SAN list so HTTPS works locally.`,
}

var dnsAliasAddCmd = &cobra.Command{
	Use:   "add <sub|fqdn> <value> <sandbox>",
	Short: "Add an alias to a sandbox",
	Args:  cobra.ExactArgs(3),
	RunE: func(cmd *cobra.Command, args []string) error {
		kind, value, sandboxName := args[0], args[1], args[2]
		if kind != "sub" && kind != "fqdn" {
			return fmt.Errorf("kind must be \"sub\" or \"fqdn\" (got %q)", kind)
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, sandboxName)
		if err != nil {
			return err
		}

		a, err := client.AddSandboxAlias(sandbox.ID, api.SandboxAliasRequest{Kind: kind, Value: value})
		if err != nil {
			return err
		}
		fmt.Printf("Added %s alias %q to sandbox %q.\n", a.Kind, a.Value, sandbox.Name)
		fmt.Printf("  FQDN: %s\n", a.FQDN)
		autoSyncHostsBestEffort(client)
		return nil
	},
}

var dnsAliasRemoveCmd = &cobra.Command{
	Use:   "remove <value> <sandbox>",
	Short: "Remove an alias from a sandbox",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		value, sandboxName := args[0], args[1]

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, sandboxName)
		if err != nil {
			return err
		}

		aliases, err := client.ListSandboxAliases(sandbox.ID)
		if err != nil {
			return err
		}
		needle := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
		var match *api.SandboxAlias
		for i, a := range aliases {
			if strings.EqualFold(a.Value, needle) || strings.EqualFold(a.FQDN, needle) {
				match = &aliases[i]
				break
			}
		}
		if match == nil {
			return fmt.Errorf("no alias %q on sandbox %q", value, sandbox.Name)
		}
		if err := client.RemoveSandboxAliasByID(sandbox.ID, match.ID); err != nil {
			return err
		}
		fmt.Printf("Removed %s alias %q from sandbox %q.\n", match.Kind, match.Value, sandbox.Name)
		autoSyncHostsBestEffort(client)
		return nil
	},
}

var dnsAliasListCmd = &cobra.Command{
	Use:   "list <sandbox>",
	Short: "List aliases for a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}
		aliases, err := client.ListSandboxAliases(sandbox.ID)
		if err != nil {
			return err
		}
		if len(aliases) == 0 {
			fmt.Printf("No aliases on sandbox %q.\n", sandbox.Name)
			return nil
		}
		w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tKIND\tVALUE\tFQDN")
		for _, a := range aliases {
			fmt.Fprintf(w, "%d\t%s\t%s\t%s\n", a.ID, a.Kind, a.Value, a.FQDN)
		}
		return w.Flush()
	},
}

func requireDarwin() error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("this command currently supports macOS only")
	}
	return nil
}

func searchDomain(instance string) (string, error) {
	if dnsSearchProject == "" {
		return instance, nil
	}
	project := dnsLabel(dnsSearchProject)
	if project == "" {
		return "", fmt.Errorf("invalid project DNS label %q", dnsSearchProject)
	}
	return project + "." + instance, nil
}

func dnsLabel(s string) string {
	return strings.Trim(strings.ToLower(strings.ReplaceAll(s, "_", "-")), ".")
}

func installProxyResolver(status *api.DNSStatus, client *api.Client, force bool) error {
	unlock, err := lockDNSState()
	if err != nil {
		return err
	}
	defer unlock()

	suffix, err := validateSuffix(status.Suffix)
	if err != nil {
		return err
	}
	upstream, err := upstreamAddress(status.ResolverIP)
	if err != nil {
		return err
	}
	state, err := loadDNSState()
	if err != nil {
		return err
	}
	prev, hadPrev := state.Proxies[suffix]
	entry := prev
	if hadPrev && (prev.ServerAlias != "" || prev.ServerURL != "") && (prev.ServerAlias != client.ServerAlias || prev.ServerURL != client.BaseURL) {
		fmt.Fprintf(os.Stderr, "warning: replacing existing DNS proxy for %s from server %s (%s)\n", suffix, valueOrDash(prev.ServerAlias), valueOrDash(prev.ServerURL))
	}
	if !hadPrev {
		port, err := pickProxyPort()
		if err != nil {
			return err
		}
		entry.LocalAddress = net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	}
	entry.Suffix = suffix
	entry.RawSuffix = status.Suffix
	entry.UpstreamAddress = upstream
	entry.LaunchdLabel = launchdLabel(suffix)
	entry.PlistPath = launchdPlistPath(entry.LaunchdLabel)
	entry.StdoutLogPath = proxyLogPath(entry.LaunchdLabel, "out.log")
	entry.StderrLogPath = proxyLogPath(entry.LaunchdLabel, "err.log")
	entry.ServerAlias = client.ServerAlias
	entry.ServerURL = client.BaseURL

	info, err := parseResolverFile(suffix)
	if err != nil {
		return err
	}
	if info.State == "unmanaged" {
		if !force {
			return fmt.Errorf("%s is not managed by Sandcastle; rerun with --force to back it up and replace it", resolverPath(suffix))
		}
		backup, err := backupResolverFile(suffix)
		if err != nil {
			return err
		}
		entry.ResolverBackupPath = backup
	}

	oldEntry := prev
	if err := writeLaunchAgent(entry); err != nil {
		return err
	}
	if err := launchdReload(entry); err != nil {
		return err
	}
	if err := waitForProxyReady(entry.LocalAddress, suffix, 5*time.Second); err != nil {
		if hadPrev {
			_ = writeLaunchAgent(oldEntry)
			_ = launchdReload(oldEntry)
		} else {
			_ = launchdUnload(entry)
			_ = os.Remove(entry.PlistPath)
		}
		return fmt.Errorf("local DNS proxy was not ready: %w; check Tailscale connectivity, subnet route approval, and server DNS state. Logs: %s", err, entry.StderrLogPath)
	}
	if err := writeResolverFile(entry); err != nil {
		if hadPrev {
			_ = writeLaunchAgent(oldEntry)
			_ = launchdReload(oldEntry)
			_ = writeResolverFile(oldEntry)
		} else {
			_ = launchdUnload(entry)
			_ = os.Remove(entry.PlistPath)
		}
		return err
	}
	if state.Proxies == nil {
		state.Proxies = make(map[string]dnsProxyState)
	}
	state.Version = 2
	state.Proxies[suffix] = entry
	if err := saveDNSState(state); err != nil {
		_ = uninstallResolverFile(suffix, entry.ResolverBackupPath)
		if hadPrev {
			_ = writeLaunchAgent(oldEntry)
			_ = launchdReload(oldEntry)
			_ = writeResolverFile(oldEntry)
		} else {
			_ = launchdUnload(entry)
			_ = os.Remove(entry.PlistPath)
		}
		return err
	}
	return nil
}

func uninstallProxyResolver(rawSuffix string) error {
	unlock, err := lockDNSState()
	if err != nil {
		return err
	}
	defer unlock()

	state, err := loadDNSState()
	if err != nil {
		return err
	}
	suffix, entry, err := resolveUninstallTarget(rawSuffix, state)
	if err != nil {
		return err
	}
	info, err := parseResolverFile(suffix)
	if err != nil {
		return err
	}
	if info.State == "unmanaged" {
		return fmt.Errorf("%s is not managed by Sandcastle; refusing to remove", resolverPath(suffix))
	}
	if err := uninstallResolverFile(suffix, entry.ResolverBackupPath); err != nil {
		return err
	}
	if entry.LaunchdLabel != "" {
		if err := launchdUnload(entry); err != nil {
			return err
		}
	}
	if entry.PlistPath != "" {
		if err := os.Remove(entry.PlistPath); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := removeManagedSearchDomainFromSystem(state, suffix); err != nil {
		return err
	}
	delete(state.Proxies, suffix)
	removeManagedSearchForSuffix(state, suffix)
	cleanupDNSState(state)
	return saveDNSState(state)
}

func writeResolverFile(entry dnsProxyState) error {
	content := renderResolverFile(entry)
	tmp, err := os.CreateTemp("", "sandcastle-resolver-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}

	if err := run("sudo", "mkdir", "-p", "/etc/resolver"); err != nil {
		return err
	}
	return run("sudo", "cp", tmp.Name(), resolverPath(entry.Suffix))
}

func uninstallResolverFile(suffix, backup string) error {
	if backup != "" {
		if _, err := os.Stat(backup); err == nil {
			if err := run("sudo", "cp", backup, resolverPath(suffix)); err != nil {
				return err
			}
			return nil
		}
	}
	path := resolverPath(suffix)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if !strings.Contains(string(data), resolverMarker) {
		return fmt.Errorf("%s is not managed by Sandcastle; refusing to remove", path)
	}
	return run("sudo", "rm", "-f", path)
}

func resolverStatus(suffix string) string {
	info, err := parseResolverFile(suffix)
	if err != nil {
		return "not installed"
	}
	switch info.State {
	case "proxy":
		return fmt.Sprintf("installed via local proxy %s", net.JoinHostPort(info.Nameserver, strconv.Itoa(info.Port)))
	case "legacy":
		return "legacy direct resolver"
	case "unmanaged":
		return "exists, not managed by Sandcastle"
	default:
		return "not installed"
	}
}

func resolverPath(suffix string) string {
	return filepath.Join(resolverRoot, suffix)
}

func renderResolverFile(entry dnsProxyState) string {
	host, port, _ := net.SplitHostPort(entry.LocalAddress)
	if host == "" {
		host = "127.0.0.1"
	}
	return fmt.Sprintf("%s\n# sandcastle_resolver_version: %s\n# sandcastle_server_alias: %s\n# sandcastle_server_url: %s\n# sandcastle_upstream: %s\ndomain %s\nnameserver %s\nport %s\nsearch_order 1\n",
		resolverMarker,
		resolverVersion,
		entry.ServerAlias,
		entry.ServerURL,
		entry.UpstreamAddress,
		entry.Suffix,
		host,
		port,
	)
}

func parseResolverFile(suffix string) (resolverInfo, error) {
	data, err := os.ReadFile(resolverPath(suffix))
	if err != nil {
		if os.IsNotExist(err) {
			return resolverInfo{State: "missing"}, nil
		}
		return resolverInfo{}, err
	}
	info := resolverInfo{State: "unmanaged", Suffix: suffix}
	if !strings.Contains(string(data), resolverMarker) {
		return info, nil
	}
	info.Managed = true
	info.State = "legacy"
	info.Legacy = true
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "# sandcastle_resolver_version:"):
			if strings.TrimSpace(strings.TrimPrefix(line, "# sandcastle_resolver_version:")) == resolverVersion {
				info.State = "proxy"
				info.Legacy = false
			}
		case strings.HasPrefix(line, "# sandcastle_server_alias:"):
			info.ServerAlias = strings.TrimSpace(strings.TrimPrefix(line, "# sandcastle_server_alias:"))
		case strings.HasPrefix(line, "# sandcastle_server_url:"):
			info.ServerURL = strings.TrimSpace(strings.TrimPrefix(line, "# sandcastle_server_url:"))
		case strings.HasPrefix(line, "# sandcastle_upstream:"):
			info.Upstream = strings.TrimSpace(strings.TrimPrefix(line, "# sandcastle_upstream:"))
		case strings.HasPrefix(line, "domain "):
			info.Domain = strings.TrimSpace(strings.TrimPrefix(line, "domain "))
		case strings.HasPrefix(line, "nameserver "):
			info.Nameserver = strings.TrimSpace(strings.TrimPrefix(line, "nameserver "))
		case strings.HasPrefix(line, "port "):
			info.Port, _ = strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "port ")))
		}
	}
	return info, nil
}

func validateSuffix(raw string) (string, error) {
	suffix := normalizeSuffix(raw)
	if suffix == "" {
		return "", fmt.Errorf("server did not return a DNS suffix")
	}
	if strings.ContainsAny(suffix, "/\x00\\") || suffix == "." || suffix == ".." {
		return "", fmt.Errorf("unsafe DNS suffix %q", raw)
	}
	for _, label := range strings.Split(suffix, ".") {
		if label == "" || label == "." || label == ".." {
			return "", fmt.Errorf("unsafe DNS suffix %q", raw)
		}
	}
	return suffix, nil
}

func normalizeSuffix(raw string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), ".")
}

func upstreamAddress(resolverIP string) (string, error) {
	host := strings.TrimSpace(resolverIP)
	if host == "" {
		return "", fmt.Errorf("DNS resolver IP is not available; enable Tailscale and approve subnet routes first")
	}
	if h, p, err := net.SplitHostPort(host); err == nil {
		if p == "" {
			p = "53"
		}
		return net.JoinHostPort(h, p), nil
	}
	if ip := net.ParseIP(host); ip == nil {
		return "", fmt.Errorf("invalid DNS resolver IP %q", resolverIP)
	}
	return net.JoinHostPort(host, "53"), nil
}

func pickProxyPort() (int, error) {
	for i := 0; i < 20; i++ {
		ln, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			return 0, err
		}
		port := ln.Addr().(*net.TCPAddr).Port
		_ = ln.Close()
		if port < 1024 {
			continue
		}
		udp, err := net.ListenPacket("udp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err == nil {
			_ = udp.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("could not find an available local DNS proxy port")
}

func launchdLabel(suffix string) string {
	sum := sha1.Sum([]byte(suffix))
	safe := strings.NewReplacer(".", "-", "_", "-", ":", "-").Replace(suffix)
	if len(safe) > 48 {
		safe = safe[:48]
	}
	return "dev.sandcastle.dns." + safe + "." + hex.EncodeToString(sum[:])[:8]
}

func launchdPlistPath(label string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist")
}

func proxyLogPath(label, name string) string {
	return filepath.Join(config.Dir(), "logs", "dns", label+"."+name)
}

func writeLaunchAgent(entry dnsProxyState) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(entry.PlistPath), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(entry.StdoutLogPath), 0o700); err != nil {
		return err
	}
	content := renderLaunchAgent(entry, exe)
	tmp, err := os.CreateTemp(filepath.Dir(entry.PlistPath), ".sandcastle-launchagent-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), entry.PlistPath)
}

func renderLaunchAgent(entry dnsProxyState, exe string) string {
	args := []string{exe, "dns", "proxy", "serve", "--listen", entry.LocalAddress, "--upstream", entry.UpstreamAddress}
	var items strings.Builder
	for _, arg := range args {
		items.WriteString("    <string>")
		items.WriteString(xmlEscape(arg))
		items.WriteString("</string>\n")
	}
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
%s  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>%s</string>
  <key>StandardErrorPath</key>
  <string>%s</string>
</dict>
</plist>
`, xmlEscape(entry.LaunchdLabel), items.String(), xmlEscape(entry.StdoutLogPath), xmlEscape(entry.StderrLogPath))
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	return strings.ReplaceAll(s, "'", "&apos;")
}

func launchdReload(entry dnsProxyState) error {
	_ = launchdUnload(entry)
	domain := launchdDomain()
	if err := run("launchctl", "bootstrap", domain, entry.PlistPath); err != nil {
		return err
	}
	return run("launchctl", "kickstart", "-k", domain+"/"+entry.LaunchdLabel)
}

func launchdUnload(entry dnsProxyState) error {
	if entry.LaunchdLabel == "" {
		return nil
	}
	err := run("launchctl", "bootout", launchdDomain()+"/"+entry.LaunchdLabel)
	if err != nil && !strings.Contains(err.Error(), "Could not find specified service") && !strings.Contains(err.Error(), "No such process") {
		return err
	}
	return nil
}

func launchdDomain() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func launchdPrint(label string) launchdStatus {
	out, err := exec.Command("launchctl", "print", launchdDomain()+"/"+label).CombinedOutput()
	if err != nil {
		return launchdStatus{Raw: strings.TrimSpace(string(out))}
	}
	text := string(out)
	return launchdStatus{
		Loaded:  true,
		Running: strings.Contains(text, "state = running") || strings.Contains(text, "pid ="),
		Raw:     strings.TrimSpace(text),
	}
}

func waitForProxyReady(localAddress, suffix string, deadline time.Duration) error {
	end := time.Now().Add(deadline)
	var last error
	for time.Now().Before(end) {
		last = dnsproxy.Probe(localAddress, suffix, 500*time.Millisecond)
		if last == nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	if last == nil {
		last = fmt.Errorf("timed out")
	}
	return last
}

func backupResolverFile(suffix string) (string, error) {
	if err := os.MkdirAll(filepath.Join(config.Dir(), "dns-backups"), 0o700); err != nil {
		return "", err
	}
	name := suffix + "." + time.Now().UTC().Format("20060102T150405Z") + ".resolver"
	path := filepath.Join(config.Dir(), "dns-backups", name)
	src, err := os.Open(resolverPath(suffix))
	if err != nil {
		return "", err
	}
	defer src.Close()
	dst, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		return "", err
	}
	return path, nil
}

func resolveUninstallTarget(raw string, state *dnsState) (string, dnsProxyState, error) {
	if raw != "" {
		suffix, err := validateSuffix(raw)
		if err != nil {
			return "", dnsProxyState{}, err
		}
		return suffix, state.Proxies[suffix], nil
	}
	if len(state.Proxies) == 1 {
		for suffix, entry := range state.Proxies {
			return suffix, entry, nil
		}
	}
	if len(state.Proxies) > 1 {
		return "", dnsProxyState{}, fmt.Errorf("multiple local DNS proxies are installed; rerun with --suffix <suffix>")
	}
	return "", dnsProxyState{}, fmt.Errorf("server unavailable or no local DNS proxy state found; rerun with --suffix <suffix>")
}

func removeManagedSearchForSuffix(state *dnsState, suffix string) {
	for service, domains := range state.Search {
		if managed, ok := domains[suffix]; ok && managed.AddedBySandcastle {
			delete(domains, suffix)
		}
		if len(domains) == 0 {
			delete(state.Search, service)
		}
	}
}

func removeManagedSearchDomainFromSystem(state *dnsState, suffix string) error {
	for service, domains := range state.Search {
		managed, ok := domains[suffix]
		if !ok || !managed.AddedBySandcastle {
			continue
		}
		current, err := getSearchDomains(service)
		if err != nil {
			return err
		}
		if err := setSearchDomains(service, removeDomain(current, suffix)); err != nil {
			return err
		}
	}
	return nil
}

func cleanupDNSState(state *dnsState) {
	if len(state.Search) == 0 {
		state.Search = nil
	}
	if len(state.Proxies) == 0 {
		state.Proxies = nil
	}
}

func lockDNSState() (func(), error) {
	if err := os.MkdirAll(config.Dir(), 0o700); err != nil {
		return nil, err
	}
	lockDir := filepath.Join(config.Dir(), "dns.lock")
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := os.Mkdir(lockDir, 0o700)
		if err == nil {
			return func() { _ = os.Remove(lockDir) }, nil
		}
		if !os.IsExist(err) {
			return nil, err
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("timed out waiting for DNS state lock %s", lockDir)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func printLocalDNSStatus(w *tabwriter.Writer, status *api.DNSStatus) error {
	state, err := loadDNSState()
	if err != nil {
		return err
	}
	targets := map[string]dnsProxyState{}
	for suffix, entry := range state.Proxies {
		targets[suffix] = entry
	}
	if status != nil && status.Suffix != "" {
		suffix := normalizeSuffix(status.Suffix)
		if _, ok := targets[suffix]; !ok {
			targets[suffix] = dnsProxyState{Suffix: suffix, UpstreamAddress: net.JoinHostPort(status.ResolverIP, "53")}
		}
	}
	if len(targets) == 0 {
		fmt.Fprintf(w, "macOS resolver:\tnot installed\n")
		return nil
	}
	suffixes := make([]string, 0, len(targets))
	for suffix := range targets {
		suffixes = append(suffixes, suffix)
	}
	sort.Strings(suffixes)
	for _, suffix := range suffixes {
		entry := targets[suffix]
		info, err := parseResolverFile(suffix)
		if err != nil {
			return err
		}
		fmt.Fprintf(w, "macOS resolver %s:\t%s\n", suffix, resolverInfoSummary(info, entry))
		if entry.LocalAddress != "" {
			fmt.Fprintf(w, "Local proxy %s:\t%s -> %s\n", suffix, entry.LocalAddress, valueOrDash(entry.UpstreamAddress))
			ls := launchdPrint(entry.LaunchdLabel)
			fmt.Fprintf(w, "LaunchAgent %s:\tloaded=%t running=%t\n", suffix, ls.Loaded, ls.Running)
			if err := dnsproxy.Probe(entry.LocalAddress, suffix, 800*time.Millisecond); err != nil {
				fmt.Fprintf(w, "Proxy probe %s:\tfailed: %v\n", suffix, err)
			} else {
				fmt.Fprintf(w, "Proxy probe %s:\tok\n", suffix)
			}
			fmt.Fprintf(w, "Proxy logs %s:\tstdout=%s stderr=%s\n", suffix, entry.StdoutLogPath, entry.StderrLogPath)
		}
	}
	return nil
}

func resolverInfoSummary(info resolverInfo, entry dnsProxyState) string {
	switch info.State {
	case "missing":
		return "missing"
	case "unmanaged":
		return "exists, not managed by Sandcastle"
	case "legacy":
		return "legacy direct Sandcastle resolver"
	case "proxy":
		wantHost, wantPort, _ := net.SplitHostPort(entry.LocalAddress)
		if entry.LocalAddress != "" && (info.Nameserver != wantHost || strconv.Itoa(info.Port) != wantPort) {
			return fmt.Sprintf("mismatch (file %s:%d, state %s)", info.Nameserver, info.Port, entry.LocalAddress)
		}
		return "installed"
	default:
		return info.State
	}
}

func suffixMessage(suffix string) string {
	if suffix == "" {
		return ""
	}
	return " for " + normalizeSuffix(suffix)
}

func writeHostsBlock(records []api.DNSRecord) error {
	current, err := os.ReadFile(hostsTargetPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", hostsTargetPath, err)
	}
	stripped, err := stripHostsBlock(current)
	if err != nil {
		return err
	}

	var block bytes.Buffer
	fmt.Fprintln(&block, hostsBeginMark)
	namesByRecord := hostsNamesForRecords(records)
	for i, r := range records {
		if r.Name == "" || r.IP == "" {
			continue
		}
		names := namesByRecord[i]
		if len(names) == 0 {
			continue
		}
		fmt.Fprintf(&block, "%s\t%s", r.IP, strings.Join(names, " "))
		if r.SandboxID != 0 {
			fmt.Fprintf(&block, "\t# sandbox %d", r.SandboxID)
		}
		fmt.Fprintln(&block)
	}
	fmt.Fprintln(&block, hostsEndMark)

	updated := stripped
	if len(updated) > 0 && !bytes.HasSuffix(updated, []byte("\n")) {
		updated = append(updated, '\n')
	}
	updated = append(updated, block.Bytes()...)
	return writeHostsFile(updated)
}

func clearHostsBlock() error {
	current, err := os.ReadFile(hostsTargetPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", hostsTargetPath, err)
	}
	stripped, err := stripHostsBlock(current)
	if err != nil {
		return err
	}
	if bytes.Equal(stripped, current) {
		return nil
	}
	return writeHostsFile(stripped)
}

func readHostsBlock() (string, error) {
	current, err := os.ReadFile(hostsTargetPath)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", hostsTargetPath, err)
	}
	begin := bytes.Index(current, []byte(hostsBeginMark))
	if begin < 0 {
		return "", nil
	}
	end := bytes.Index(current[begin:], []byte(hostsEndMark))
	if end < 0 {
		return "", fmt.Errorf("%s contains %q without matching %q", hostsTargetPath, hostsBeginMark, hostsEndMark)
	}
	end += begin + len(hostsEndMark)
	if eol := bytes.IndexByte(current[end:], '\n'); eol >= 0 {
		end += eol + 1
	}
	return string(current[begin:end]), nil
}

func stripHostsBlock(data []byte) ([]byte, error) {
	begin := bytes.Index(data, []byte(hostsBeginMark))
	if begin < 0 {
		if bytes.Contains(data, []byte(hostsEndMark)) {
			return nil, fmt.Errorf("%s contains %q without matching %q; refusing to edit", hostsTargetPath, hostsEndMark, hostsBeginMark)
		}
		return data, nil
	}
	end := bytes.Index(data[begin:], []byte(hostsEndMark))
	if end < 0 {
		return nil, fmt.Errorf("%s contains %q without matching %q; refusing to edit", hostsTargetPath, hostsBeginMark, hostsEndMark)
	}
	end += begin + len(hostsEndMark)
	if eol := bytes.IndexByte(data[end:], '\n'); eol >= 0 {
		end += eol + 1
	}
	// Also drop a single blank line that we may have inserted before the block.
	prefix := data[:begin]
	if bytes.HasSuffix(prefix, []byte("\n\n")) {
		prefix = prefix[:len(prefix)-1]
	}
	out := make([]byte, 0, len(prefix)+len(data)-end)
	out = append(out, prefix...)
	out = append(out, data[end:]...)
	return out, nil
}

func hostsNamesForRecords(records []api.DNSRecord) [][]string {
	candidates := make([][]string, len(records))
	owner := make(map[string]int)
	duplicate := make(map[string]bool)

	for i, r := range records {
		if r.Name == "" || r.IP == "" {
			continue
		}
		if r.Expand {
			candidates[i] = hostsAliases(r.Name)
		} else {
			candidates[i] = []string{r.Name}
		}

		seenInRecord := make(map[string]bool)
		for _, name := range candidates[i] {
			if name == "" || seenInRecord[name] {
				continue
			}
			seenInRecord[name] = true
			if previous, ok := owner[name]; ok && previous != i {
				duplicate[name] = true
				continue
			}
			owner[name] = i
		}
	}

	namesByRecord := make([][]string, len(records))
	for i, r := range records {
		if r.Name == "" || r.IP == "" {
			continue
		}

		seen := make(map[string]bool)
		add := func(name string) {
			if name == "" || seen[name] {
				return
			}
			seen[name] = true
			namesByRecord[i] = append(namesByRecord[i], name)
		}

		// Keep the full DNS record as the canonical hostname. macOS groups
		// /etc/hosts results by canonical name, so using short aliases first
		// can make unrelated FQDN lookups inherit each other's IPs.
		add(r.Name)
		for _, name := range candidates[i] {
			if name == r.Name || duplicate[name] {
				continue
			}
			add(name)
		}
	}

	return namesByRecord
}

func hostsAliases(fqdn string) []string {
	parts := strings.Split(fqdn, ".")
	out := make([]string, 0, len(parts))
	for i := 1; i <= len(parts); i++ {
		out = append(out, strings.Join(parts[:i], "."))
	}
	return out
}

func writeHostsFile(data []byte) error {
	tmp, err := os.CreateTemp("", "sandcastle-hosts-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := run("sudo", "cp", tmp.Name(), hostsTargetPath); err != nil {
		return err
	}
	return run("sudo", "chmod", "644", hostsTargetPath)
}

func addSearchDomain(domain string) error {
	unlock, err := lockDNSState()
	if err != nil {
		return err
	}
	defer unlock()
	state, err := loadDNSState()
	if err != nil {
		return err
	}
	services, err := targetServices()
	if err != nil {
		return err
	}
	for _, service := range services {
		domains, err := getSearchDomains(service)
		if err != nil {
			return err
		}
		already := contains(domains, domain)
		if !already {
			domains = append(domains, domain)
			if err := setSearchDomains(service, domains); err != nil {
				return err
			}
		}
		rememberSearchDomain(state, service, domain, !already)
	}
	return saveDNSState(state)
}

func removeSearchDomain(domain string) error {
	unlock, err := lockDNSState()
	if err != nil {
		return err
	}
	defer unlock()
	state, err := loadDNSState()
	if err != nil {
		return err
	}
	services, err := targetServices()
	if err != nil {
		return err
	}
	for _, service := range services {
		managed, ok := state.Search[service][domain]
		if !ok || !managed.AddedBySandcastle {
			continue
		}
		domains, err := getSearchDomains(service)
		if err != nil {
			return err
		}
		next := removeDomain(domains, domain)
		if err := setSearchDomains(service, next); err != nil {
			return err
		}
		delete(state.Search[service], domain)
	}
	return saveDNSState(state)
}

func rememberSearchDomain(state *dnsState, service, domain string, added bool) {
	if state.Search == nil {
		state.Search = make(map[string]map[string]managedSearchDomain)
	}
	if state.Search[service] == nil {
		state.Search[service] = make(map[string]managedSearchDomain)
	}
	state.Search[service][domain] = managedSearchDomain{AddedBySandcastle: added}
}

func targetServices() ([]string, error) {
	if dnsSearchService != "" {
		return []string{dnsSearchService}, nil
	}
	services, err := listNetworkServices()
	if err != nil {
		return nil, err
	}
	if dnsSearchAll {
		return services, nil
	}
	if len(services) == 0 {
		return nil, fmt.Errorf("no enabled macOS network services found")
	}
	return []string{services[0]}, nil
}

func listNetworkServices() ([]string, error) {
	ordered, err := listNetworkServiceOrder()
	if err == nil && len(ordered) > 0 {
		return ordered, nil
	}

	out, err := exec.Command("/usr/sbin/networksetup", "-listallnetworkservices").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(out), "\n")
	var services []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "An asterisk") || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	return services, nil
}

func listNetworkServiceOrder() ([]string, error) {
	out, err := exec.Command("/usr/sbin/networksetup", "-listnetworkserviceorder").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(out), "\n")
	var services []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "(") {
			continue
		}
		end := strings.Index(line, ") ")
		if end < 0 || end+2 >= len(line) {
			continue
		}
		name := strings.TrimSpace(line[end+2:])
		if name == "" || strings.HasPrefix(name, "*") || strings.HasPrefix(name, "Hardware Port:") {
			continue
		}
		services = append(services, name)
	}
	return services, nil
}

func getSearchDomains(service string) ([]string, error) {
	out, err := exec.Command("/usr/sbin/networksetup", "-getsearchdomains", service).Output()
	if err != nil {
		return nil, err
	}
	text := strings.TrimSpace(string(out))
	if text == "" || strings.Contains(text, "There aren't any Search Domains") {
		return nil, nil
	}
	return strings.Fields(text), nil
}

func setSearchDomains(service string, domains []string) error {
	args := []string{"/usr/sbin/networksetup", "-setsearchdomains", service}
	if len(domains) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, domains...)
	}
	fmt.Printf("Running: sudo %s\n", strings.Join(shellQuote(args), " "))
	return run("sudo", args...)
}

func loadDNSState() (*dnsState, error) {
	state := &dnsState{Search: make(map[string]map[string]managedSearchDomain), Proxies: make(map[string]dnsProxyState)}
	data, err := os.ReadFile(dnsStatePath())
	if err != nil {
		if os.IsNotExist(err) {
			return state, nil
		}
		return nil, err
	}
	if err := yaml.Unmarshal(data, state); err != nil {
		return nil, err
	}
	if state.Search == nil {
		state.Search = make(map[string]map[string]managedSearchDomain)
	}
	if state.Proxies == nil {
		state.Proxies = make(map[string]dnsProxyState)
	}
	return state, nil
}

func saveDNSState(state *dnsState) error {
	if err := os.MkdirAll(config.Dir(), 0o700); err != nil {
		return err
	}
	data, err := yaml.Marshal(state)
	if err != nil {
		return err
	}
	return os.WriteFile(dnsStatePath(), data, 0o600)
}

func dnsStatePath() string {
	return filepath.Join(config.Dir(), "dns.yaml")
}

func contains(items []string, target string) bool {
	for _, item := range items {
		if item == target {
			return true
		}
	}
	return false
}

func removeDomain(items []string, target string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		if item != target {
			out = append(out, item)
		}
	}
	return out
}

func displayDomains(domains []string) string {
	if len(domains) == 0 {
		return "—"
	}
	sort.Strings(domains)
	return strings.Join(domains, ", ")
}

func shellQuote(args []string) []string {
	out := make([]string, len(args))
	for i, arg := range args {
		if strings.ContainsAny(arg, " \t\n'\"") {
			out[i] = "'" + strings.ReplaceAll(arg, "'", "'\\''") + "'"
		} else {
			out[i] = arg
		}
	}
	return out
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.Stdout = os.Stdout
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return fmt.Errorf("%s: %w", msg, err)
		}
		return err
	}
	return nil
}
