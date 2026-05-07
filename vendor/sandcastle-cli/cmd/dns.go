package cmd

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
	"gopkg.in/yaml.v3"
)

const (
	resolverMarker  = "# Managed by sandcastle dns"
	hostsBeginMark  = "# BEGIN sandcastle-dns"
	hostsEndMark    = "# END sandcastle-dns"
	hostsTargetPath = "/etc/hosts"
)

var (
	dnsInstallSearch bool
	dnsSearchProject string
	dnsSearchService string
	dnsSearchAll     bool
)

type dnsState struct {
	Search map[string]map[string]managedSearchDomain `yaml:"search,omitempty"`
}

type managedSearchDomain struct {
	AddedBySandcastle bool `yaml:"added_by_sandcastle"`
}

func init() {
	rootCmd.AddCommand(dnsCmd)
	dnsCmd.AddCommand(dnsStatusCmd)
	dnsCmd.AddCommand(dnsInstallCmd)
	dnsCmd.AddCommand(dnsUninstallCmd)
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
}

var dnsCmd = &cobra.Command{
	Use:   "dns",
	Short: "Manage Sandcastle DNS on this client",
}

var dnsStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Sandcastle DNS status",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		status, err := client.DNSStatus()
		if err != nil {
			return err
		}

		w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
		fmt.Fprintf(w, "Suffix:\t%s\n", valueOrDash(status.Suffix))
		fmt.Fprintf(w, "Resolver IP:\t%s\n", valueOrDash(status.ResolverIP))
		fmt.Fprintf(w, "Tailscale IP:\t%s\n", valueOrDash(status.TailscaleIP))
		fmt.Fprintf(w, "Resolver running:\t%t\n", status.ResolverRunning)
		fmt.Fprintf(w, "Network:\t%s\n", valueOrDash(status.Network))
		fmt.Fprintf(w, "Hosts file:\t%s\n", valueOrDash(status.HostsPath))
		if runtime.GOOS == "darwin" && status.Suffix != "" {
			fmt.Fprintf(w, "macOS resolver:\t%s\n", resolverStatus(status.Suffix))
		}
		w.Flush()

		if len(status.Records) > 0 {
			fmt.Println()
			w = tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "NAME\tIP")
			for _, r := range status.Records {
				fmt.Fprintf(w, "%s\t%s\n", r.Name, r.IP)
			}
			w.Flush()
		}

		if len(status.Skipped) > 0 {
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
	Short: "Install macOS resolver configuration for Sandcastle DNS",
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

		if err := installResolver(status.Suffix, status.ResolverIP); err != nil {
			return err
		}
		fmt.Printf("Installed /etc/resolver/%s -> %s\n", status.Suffix, status.ResolverIP)

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
		if err := uninstallResolver(status.Suffix); err != nil {
			return err
		}
		fmt.Printf("Removed /etc/resolver/%s\n", status.Suffix)
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
		"Useful when /etc/resolver-based DNS is unreliable (for example when the\n" +
		"resolver is reached over Tailscale and macOS treats it as transient).",
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

		status, err := client.DNSStatus()
		if err != nil {
			return err
		}
		if len(status.Records) == 0 {
			fmt.Println("No DNS records returned by server; clearing managed block.")
			return clearHostsBlock()
		}
		if err := writeHostsBlock(status.Records); err != nil {
			return err
		}
		fmt.Printf("Wrote %d entries to %s\n", len(status.Records), hostsTargetPath)
		return nil
	},
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
		fmt.Println("Run `sandcastle dns hosts sync` to update /etc/hosts.")
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
		fmt.Println("Run `sandcastle dns hosts sync` to update /etc/hosts.")
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

func installResolver(suffix, resolverIP string) error {
	content := fmt.Sprintf("%s\n# Server: %s\nnameserver %s\nsearch_order 1\n", resolverMarker, suffix, resolverIP)
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
	return run("sudo", "cp", tmp.Name(), resolverPath(suffix))
}

func uninstallResolver(suffix string) error {
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
	data, err := os.ReadFile(resolverPath(suffix))
	if err != nil {
		return "not installed"
	}
	if strings.Contains(string(data), resolverMarker) {
		return "installed"
	}
	return "exists, not managed by Sandcastle"
}

func resolverPath(suffix string) string {
	return filepath.Join("/etc/resolver", suffix)
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
	for _, r := range records {
		if r.Name == "" || r.IP == "" {
			continue
		}
		names := hostsAliases(r.Name)
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
	state := &dnsState{Search: make(map[string]map[string]managedSearchDomain)}
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
