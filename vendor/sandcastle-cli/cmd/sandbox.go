package cmd

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

var (
	sandboxImage             string
	sandboxSnapshot          string
	sandboxFromSnapshot      string
	sandboxRestoreLayers     string
	sandboxTailscale         bool
	sandboxNoConnect         bool
	sandboxRemove            bool
	sandboxHome              bool
	sandboxHomeSubdir        string
	sandboxProject           string
	sandboxProjectSubdir     string
	sandboxData              string
	sandboxStorage           string
	sandboxNoVNC             bool
	sandboxVNCGeometry       string
	sandboxVNCDepth          int
	sandboxNoDocker          bool
	sandboxSMB               bool
	sandboxOIDC              bool
	sandboxNoOIDC            bool
	sandboxGCP               bool
	sandboxGCPConfig         string
	sandboxGCPServiceAccount string
	sandboxGCPScope          string
	sandboxGCPRoles          []string
	listArchived             bool
)

func init() {
	rootCmd.AddCommand(createCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(deleteCmd)
	deleteCmd.Flags().BoolVarP(&deleteForce, "force", "f", false, "Skip confirmation prompt")
	rootCmd.AddCommand(startCmd)
	rootCmd.AddCommand(stopCmd)
	rootCmd.AddCommand(rebuildCmd)
	rootCmd.AddCommand(useCmd)
	rootCmd.AddCommand(setCmd)
	rootCmd.AddCommand(renameCmd)
	rootCmd.AddCommand(archiveRestoreCmd)

	listCmd.Flags().BoolVar(&listArchived, "archived", false, "List archived (soft-deleted) sandboxes")

	createCmd.Flags().StringVar(&sandboxImage, "image", "ghcr.io/thieso2/sandcastle-sandbox:latest", "Container image")
	createCmd.Flags().StringVar(&sandboxSnapshot, "snapshot", "", "Create from snapshot (legacy alias for --from-snapshot)")
	createCmd.Flags().StringVar(&sandboxFromSnapshot, "from-snapshot", "", "Create from snapshot name (restores all available layers)")
	createCmd.Flags().StringVar(&sandboxRestoreLayers, "restore-layers", "", "Comma-separated layers to restore: container,home,data (default: all)")
	createCmd.Flags().BoolVar(&sandboxTailscale, "tailscale", false, "Connect to Tailscale network")
	createCmd.Flags().BoolVarP(&sandboxNoConnect, "no-connect", "n", false, "Don't connect after creation")
	createCmd.Flags().BoolVar(&sandboxRemove, "rm", false, "Delete sandbox on exit (env: SANDCASTLE_RM)")
	createCmd.Flags().BoolVar(&sandboxHome, "home", false, "Mount persistent home directory (env: SANDCASTLE_HOME)")
	createCmd.Flags().StringVar(&sandboxHomeSubdir, "home-subdir", "", "Mount this subdir of persistent home as $HOME")
	createCmd.Flags().StringVar(&sandboxProject, "project", "", "Create the sandbox from a saved project preset")
	createCmd.Flags().StringVar(&sandboxProjectSubdir, "project-subdir", "", "Mount this subdir as both $HOME and /persisted")
	createCmd.Flags().StringVar(&sandboxData, "data", "", "Mount user data directory (or subpath) to /persisted (env: SANDCASTLE_DATA)")
	createCmd.Flags().Lookup("data").NoOptDefVal = "."
	createCmd.Flags().StringVar(&sandboxStorage, "storage", "direct", "Persistent storage write behavior: direct or snapshot")
	createCmd.Flags().BoolVar(&sandboxNoVNC, "no-vnc", false, "Disable VNC display server")
	createCmd.Flags().StringVar(&sandboxVNCGeometry, "vnc-geometry", "", "VNC screen resolution (e.g. 1920x1080)")
	createCmd.Flags().IntVar(&sandboxVNCDepth, "vnc-depth", 0, "VNC color depth: 8, 16, 24, or 32")
	createCmd.Flags().BoolVar(&sandboxNoDocker, "no-docker", false, "Disable Docker daemon (DinD) inside sandbox")
	createCmd.Flags().BoolVar(&sandboxSMB, "smb", false, "Enable SMB file sharing (requires Tailscale and SMB password set via 'sandcastle smb set-password')")
	createCmd.Flags().BoolVar(&sandboxOIDC, "oidc", false, "Enable sandbox OIDC identity tokens")
	createCmd.Flags().BoolVar(&sandboxNoOIDC, "no-oidc", false, "Disable sandbox OIDC identity tokens")
	createCmd.Flags().BoolVar(&sandboxGCP, "gcp", false, "Configure GCP credentials for this sandbox")
	createCmd.Flags().StringVar(&sandboxGCPConfig, "gcp-config", "", "GCP identity config name or ID")
	createCmd.Flags().StringVar(&sandboxGCPServiceAccount, "gcp-service-account", "", "GCP service account email to impersonate")
	createCmd.Flags().StringVar(&sandboxGCPScope, "gcp-scope", "user", "GCP principal scope: user or sandbox")
	createCmd.Flags().StringArrayVar(&sandboxGCPRoles, "gcp-role", nil, "GCP project IAM role hint; may be repeated")
}

var createCmd = &cobra.Command{
	Use:     "create [name]",
	Aliases: []string{"cr"},
	Short:   "Create a new sandbox",
	Long: `Create a new sandbox.

If no name is provided, creates a temporary sandbox with an auto-generated name like "temp-<timestamp>".

Environment variables can set defaults for commonly used flags:
  SANDCASTLE_HOME=1    equivalent to --home
  SANDCASTLE_DATA=.    equivalent to --data (value is the subpath, "." or "1" for root)
  SANDCASTLE_RM=1      equivalent to --rm

Flags explicitly passed on the command line take precedence over environment variables.`,
	Args: cobra.MaximumNArgs(1),
	PreRun: func(cmd *cobra.Command, args []string) {
		// Priority: explicit flag > env var > config preference
		cfg, _ := config.Load()
		prefs := cfg.LoadPreferences()

		if !cmd.Flags().Changed("home") {
			if prefs.MountHome != nil && *prefs.MountHome {
				sandboxHome = true
			}
		}
		if !cmd.Flags().Changed("rm") && envTruthy("SANDCASTLE_RM") {
			sandboxRemove = true
		}
		if !cmd.Flags().Changed("data") {
			if prefs.DataPath != "" {
				sandboxData = prefs.DataPath
			}
		}
		if !cmd.Flags().Changed("no-vnc") {
			if prefs.VNC != nil && !*prefs.VNC {
				sandboxNoVNC = true
			}
		}
		if !cmd.Flags().Changed("no-docker") {
			if prefs.Docker != nil && !*prefs.Docker {
				sandboxNoDocker = true
			}
		}
	},
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		// Auto-generate name if not provided
		var name string
		autoGenerated := false
		if len(args) == 0 {
			name = fmt.Sprintf("temp-%d", time.Now().Unix())
			autoGenerated = true
			// Auto-generated sandboxes are temporary by default
			if !cmd.Flags().Changed("rm") {
				sandboxRemove = true
			}
		} else {
			name = args[0]
		}

		// Resolve snapshot flags: --from-snapshot takes precedence over --snapshot
		fromSnap := sandboxFromSnapshot
		if fromSnap == "" {
			fromSnap = sandboxSnapshot
		}

		var restoreLayers []string
		if sandboxRestoreLayers != "" {
			for _, l := range strings.Split(sandboxRestoreLayers, ",") {
				restoreLayers = append(restoreLayers, strings.TrimSpace(l))
			}
		}
		if sandboxStorage != "direct" && sandboxStorage != "snapshot" {
			return fmt.Errorf("invalid storage mode %q: must be direct or snapshot", sandboxStorage)
		}
		if sandboxOIDC && sandboxNoOIDC {
			return fmt.Errorf("--oidc and --no-oidc are mutually exclusive")
		}
		if sandboxNoOIDC && (sandboxGCP || sandboxGCPConfig != "" || sandboxGCPServiceAccount != "") {
			return fmt.Errorf("--no-oidc cannot be used with GCP credential configuration")
		}
		if sandboxGCPScope != "sandbox" && sandboxGCPScope != "user" {
			return fmt.Errorf("--gcp-scope must be sandbox or user")
		}
		var oidcEnabled *bool
		if cmd.Flags().Changed("oidc") {
			v := true
			oidcEnabled = &v
		}
		if cmd.Flags().Changed("no-oidc") {
			v := false
			oidcEnabled = &v
		}
		var gcpConfigID int
		if sandboxGCPConfig != "" {
			config, err := findGcpConfig(client, sandboxGCPConfig)
			if err != nil {
				return err
			}
			gcpConfigID = config.ID
		}
		if oidcEnabled == nil && (sandboxGCP || sandboxGCPConfig != "" || sandboxGCPServiceAccount != "") {
			v := true
			oidcEnabled = &v
		}

		if sandboxHome && sandboxHomeSubdir != "" {
			return fmt.Errorf("--home and --home-subdir are mutually exclusive")
		}
		if sandboxProject != "" && sandboxProjectSubdir != "" {
			return fmt.Errorf("--project and --project-subdir cannot be combined")
		}

		req := api.CreateSandboxRequest{
			Name:                   name,
			Image:                  sandboxImage,
			FromSnapshot:           fromSnap,
			RestoreLayers:          restoreLayers,
			Tailscale:              sandboxTailscale,
			MountHome:              sandboxHome,
			HomePath:               sandboxHomeSubdir,
			DataPath:               sandboxData,
			StorageMode:            sandboxStorage,
			Temporary:              sandboxRemove,
			VNCEnabled:             !sandboxNoVNC,
			VNCGeometry:            sandboxVNCGeometry,
			VNCDepth:               sandboxVNCDepth,
			DockerEnabled:          !sandboxNoDocker,
			SMBEnabled:             sandboxSMB,
			OIDCEnabled:            oidcEnabled,
			GCPOIDCEnabled:         sandboxGCP || sandboxGCPConfig != "" || sandboxGCPServiceAccount != "",
			GCPOIDCConfigID:        gcpConfigID,
			GCPServiceAccountEmail: sandboxGCPServiceAccount,
			GCPPrincipalScope:      sandboxGCPScope,
			GCPRoles:               cleanStringList(sandboxGCPRoles),
		}
		if sandboxProject != "" {
			req.ProjectName = sandboxProject
		}
		if sandboxProjectSubdir != "" {
			req.ProjectPath = sandboxProjectSubdir
			req.HomePath = ""
			req.MountHome = false
			req.DataPath = ""
		}
		sandbox, err := client.CreateSandbox(req)
		if err != nil {
			return err
		}

		if autoGenerated {
			fmt.Printf("Sandbox %q created (auto-generated name).\n", sandbox.DisplayName())
		} else {
			fmt.Printf("Sandbox %q created.\n", sandbox.DisplayName())
		}

		// Print active options (use local flags — they reflect what was actually requested)
		if sandboxHome || sandboxHomeSubdir != "" || sandboxProject != "" || sandboxProjectSubdir != "" || sandboxData != "" || sandboxStorage != "direct" || sandbox.Tailscale || sandboxRemove || fromSnap != "" || sandboxNoVNC || sandboxVNCGeometry != "" || sandboxVNCDepth != 0 || sandboxNoDocker || sandboxSMB || sandboxGCP || sandboxGCPConfig != "" || sandboxGCPServiceAccount != "" {
			if sandboxHome {
				fmt.Println("  Home:      mounted (~/ persisted)")
			}
			if sandboxHomeSubdir != "" {
				fmt.Printf("  Home:      mounted (%s → $HOME)\n", sandboxHomeSubdir)
			}
			if sandboxProject != "" {
				fmt.Printf("  Project:   %s\n", sandboxProject)
			}
			if sandboxProjectSubdir != "" {
				fmt.Printf("  Project:   %s (scoped home + persisted)\n", sandboxProjectSubdir)
			}
			if sandboxData != "" {
				label := sandboxData
				if label == "." {
					label = "user data root"
				}
				fmt.Printf("  Data:      mounted (%s → /persisted)\n", label)
			}
			if sandboxStorage != "direct" {
				fmt.Printf("  Storage:   %s\n", sandboxStorage)
			}
			if sandbox.Tailscale {
				fmt.Println("  Tailscale: enabled")
			}
			if sandboxRemove {
				fmt.Println("  Cleanup:   auto-remove on exit")
			}
			if fromSnap != "" {
				fmt.Printf("  Snapshot:  restored from %q\n", fromSnap)
			}
			if sandboxNoDocker {
				fmt.Println("  Docker:    disabled")
			}
			if sandboxNoVNC {
				fmt.Println("  VNC:       disabled")
			} else if sandboxVNCGeometry != "" || sandboxVNCDepth != 0 {
				geom := sandbox.VNCGeometry
				if geom == "" {
					geom = "1280x900"
				}
				depth := sandbox.VNCDepth
				if depth == 0 {
					depth = 24
				}
				fmt.Printf("  VNC:       %s @ %d-bit\n", geom, depth)
			}
			if sandboxSMB {
				fmt.Println("  SMB:       enabled")
			}
			if sandboxGCP || sandboxGCPConfig != "" || sandboxGCPServiceAccount != "" {
				fmt.Println("  GCP:       configured")
			}
		}

		if sandboxNoConnect {
			return nil
		}

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		if os.Getenv("VERBOSE") == "1" {
			fmt.Fprintf(os.Stderr, "\033[2m[verbose] Connection info: host=%s port=%d user=%s\033[0m\n", info.Host, info.Port, info.User)
			if info.TailscaleIP != "" {
				fmt.Fprintf(os.Stderr, "\033[2m[verbose] Tailscale IP (Tailscale): %s\033[0m\n", info.TailscaleIP)
			}
		}

		if err := checkHostReachable(info.Host, info.Port); err != nil {
			return err
		}

		if err := waitForSSH(info.Host, info.Port); err != nil {
			return err
		}

		cfg, loadErr := config.Load()
		if loadErr != nil {
			return loadErr
		}
		prefs := cfg.LoadPreferences()

		var remoteCmd string
		if *prefs.UseTmux {
			remoteCmd = tmuxCmd
		}

		var sshErr error
		if pickProtocol(cfg, info.Host, info.Port, info.User, prefs.SSHExtraArgs) == "mosh" {
			fmt.Fprintf(os.Stderr, "\033[33mWarning:\033[0m mosh does not support SSH agent forwarding. Use --mosh=no if you need ssh-add keys inside the sandbox.\n")
			sshErr = moshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs, nil)
		} else {
			sshErr = sshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs, nil)
		}

		if sandboxRemove {
			// Re-fetch to check if user toggled to "keep" during the session
			current, fetchErr := client.GetSandbox(sandbox.ID)
			if fetchErr == nil && !current.Temporary {
				fmt.Printf("Sandbox %q was set to keep — skipping removal.\n", sandbox.DisplayName())
			} else {
				fmt.Printf("Removing sandbox %q...\n", sandbox.DisplayName())
				if err := client.DestroySandbox(sandbox.ID); err != nil {
					fmt.Fprintf(os.Stderr, "Warning: failed to delete sandbox: %v\n", err)
				} else {
					fmt.Printf("Sandbox %q deleted.\n", sandbox.DisplayName())
				}
			}
		}

		return sshErr
	},
}

var listCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List all sandboxes",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		if listArchived {
			sandboxes, err := client.ListArchivedSandboxes()
			if err != nil {
				return err
			}
			if len(sandboxes) == 0 {
				fmt.Println("No archived sandboxes.")
				return nil
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tNAME\tARCHIVED\tCREATED\tIMAGE")
			for _, s := range sandboxes {
				archivedAt := ""
				if s.ArchivedAt != nil {
					archivedAt = s.ArchivedAt.Local().Format("2006-01-02 15:04")
				}
				created := s.CreatedAt.Local().Format("2006-01-02 15:04")
				fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", s.ID, s.DisplayName(), archivedAt, created, s.Image)
			}
			w.Flush()
			return nil
		}

		sandboxes, err := client.ListSandboxes()
		if err != nil {
			return err
		}

		if len(sandboxes) == 0 {
			fmt.Println("No sandboxes.")
			return nil
		}

		hasRoute := false
		hasProject := false
		for _, s := range sandboxes {
			if len(s.Routes) > 0 {
				hasRoute = true
			}
			if s.ProjectName != "" {
				hasProject = true
			}
		}
		dnsNames := dnsNamesBySandboxID(client)
		hasDNS := len(dnsNames) > 0

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

		headers := []string{"NAME"}
		if hasProject {
			headers = append(headers, "PROJECT")
		}
		headers = append(headers, "STATUS", "CREATED")
		if hasRoute {
			headers = append(headers, "ROUTE")
		}
		if hasDNS {
			headers = append(headers, "DNS")
		}
		headers = append(headers, "TAILSCALE IP", "IMAGE AGE")
		fmt.Fprintln(w, strings.Join(headers, "\t"))

		for _, s := range sandboxes {
			name := s.Name
			if s.Temporary {
				name += " (temp)"
			}
			tsIP := s.TailscaleIP
			created := s.CreatedAt.Local().Format("2006-01-02 15:04")
			imageAge := formatImageAge(s.ImageBuiltAt)

			cols := []string{name}
			if hasProject {
				cols = append(cols, s.ProjectName)
			}
			cols = append(cols, s.Status, created)
			if hasRoute {
				route := ""
				if len(s.Routes) > 0 {
					parts := make([]string, len(s.Routes))
					for i, r := range s.Routes {
						parts[i] = fmt.Sprintf("%s (:%d)", r.URL, r.Port)
					}
					route = strings.Join(parts, ", ")
				}
				cols = append(cols, route)
			}
			if hasDNS {
				cols = append(cols, dnsNames[s.ID])
			}
			cols = append(cols, tsIP, imageAge)
			fmt.Fprintln(w, strings.Join(cols, "\t"))
		}
		w.Flush()
		return nil
	},
}

func dnsNamesBySandboxID(client *api.Client) map[int]string {
	status, err := client.DNSStatus()
	if err != nil || status == nil || len(status.Records) == 0 {
		return nil
	}

	names := make(map[int]string, len(status.Records))
	for _, record := range status.Records {
		if record.SandboxID == 0 || record.Name == "" {
			continue
		}
		names[record.SandboxID] = record.Name
	}
	return names
}

var archiveRestoreCmd = &cobra.Command{
	Use:   "unarchive <id>",
	Short: "Restore an archived sandbox",
	Long: `Restore an archived sandbox by its ID, recreating the container from the preserved volume.
The sandbox is restored in running state. Use 'sandcastle list --archived' to see IDs.`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		id, err := strconv.Atoi(args[0])
		if err != nil {
			return fmt.Errorf("invalid sandbox ID %q: must be a number (use 'sandcastle list --archived' to see IDs)", args[0])
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := client.ArchiveRestoreSandbox(id)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q restored (status: %s).\n", sandbox.DisplayName(), sandbox.Status)
		return nil
	},
}

var deleteForce bool

var deleteCmd = &cobra.Command{
	Use:     "delete <name>",
	Aliases: []string{"rm", "d"},
	Short:   "Delete a sandbox",
	Args:    cobra.ExactArgs(1),
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

		if !deleteForce {
			fmt.Printf("Are you sure you want to delete sandbox %q? [y/N] ", sandbox.DisplayName())
			scanner := bufio.NewScanner(os.Stdin)
			scanner.Scan()
			answer := strings.TrimSpace(strings.ToLower(scanner.Text()))
			if answer != "y" && answer != "yes" {
				fmt.Println("Aborted.")
				return nil
			}
		}

		if err := client.DestroySandbox(sandbox.ID); err != nil {
			return err
		}

		fmt.Printf("Sandbox %q deleted.\n", sandbox.DisplayName())
		return nil
	},
}

var startCmd = &cobra.Command{
	Use:     "start <name>",
	Aliases: []string{"up"},
	Short:   "Start a stopped sandbox",
	Args:    cobra.ExactArgs(1),
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

		sandbox, err = client.StartSandbox(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q started.\n", sandbox.DisplayName())
		return nil
	},
}

var stopCmd = &cobra.Command{
	Use:     "stop <name>",
	Aliases: []string{"dn"},
	Short:   "Stop a running sandbox",
	Args:    cobra.ExactArgs(1),
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

		sandbox, err = client.StopSandbox(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q stopped.\n", sandbox.DisplayName())
		return nil
	},
}

var rebuildCmd = &cobra.Command{
	Use:   "rebuild <name>",
	Short: "Rebuild a sandbox with the latest image",
	Long:  `Destroys and recreates the container from the latest image. Bind-mounted data (home, persisted) is preserved but file ownership may shift due to Sysbox UID remapping. Use "start" for a quick restart that preserves ownership.`,
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

		sandbox, err = client.RebuildSandbox(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q rebuilding with latest image.\n", sandbox.DisplayName())
		return nil
	},
}

var useCmd = &cobra.Command{
	Use:   "use [name]",
	Short: "Show or set active server/sandbox",
	Long: `Without arguments, shows the current server and active sandbox.
With an argument, switches the active server or sandbox.

Examples:
  sandcastle use                  # Show current server and sandbox
  sandcastle use my-sandbox       # Set active sandbox
  sandcastle use prod             # Switch to server "prod" (if configured)`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		// No args: list all servers, highlight active
		if len(args) == 0 {
			if len(cfg.Servers) == 0 {
				fmt.Println("No servers configured — run: sandcastle login <url>")
				return nil
			}

			aliases := make([]string, 0, len(cfg.Servers))
			for alias := range cfg.Servers {
				aliases = append(aliases, alias)
			}
			sort.Strings(aliases)

			for _, alias := range aliases {
				srv := cfg.Servers[alias]
				if alias == cfg.CurrentServer {
					fmt.Printf("  \033[1m* %-16s\033[0m %s\n", alias, srv.URL)
				} else {
					fmt.Printf("    %-16s %s\n", alias, srv.URL)
				}
			}

			return nil
		}

		name := args[0]

		// Check if name matches a server alias or URL
		if _, ok := cfg.Servers[name]; ok {
			cfg.CurrentServer = name
			if err := config.Save(cfg); err != nil {
				return err
			}
			fmt.Printf("Switched to server %s (%s)\n", name, cfg.Servers[name].URL)
			return nil
		}

		// Try matching by URL
		for alias, srv := range cfg.Servers {
			if srv.URL == strings.TrimRight(name, "/") {
				cfg.CurrentServer = alias
				if err := config.Save(cfg); err != nil {
					return err
				}
				fmt.Printf("Switched to server %s (%s)\n", alias, srv.URL)
				return nil
			}
		}

		return fmt.Errorf("server %q not found — run: sandcastle use", name)
	},
}

var setCmd = &cobra.Command{
	Use:   "set <name> <temp|keep>",
	Short: "Toggle sandbox between temporary and kept",
	Long: `Toggle a sandbox between temporary (auto-remove on exit) and kept.

  temp   Mark as temporary — will be removed when the CLI session exits
  keep   Mark as kept — will not be auto-removed`,
	Args: cobra.ExactArgs(2),
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

		mode := strings.ToLower(args[1])
		var temp bool
		switch mode {
		case "temp":
			temp = true
		case "keep":
			temp = false
		default:
			return fmt.Errorf("unknown mode %q: use \"temp\" or \"keep\"", args[1])
		}

		sandbox, err = client.UpdateSandbox(sandbox.ID, api.UpdateSandboxRequest{Temporary: &temp})
		if err != nil {
			return err
		}

		if temp {
			fmt.Printf("Sandbox %q set to temporary (will be removed on exit).\n", sandbox.DisplayName())
		} else {
			fmt.Printf("Sandbox %q set to keep (will not be removed on exit).\n", sandbox.DisplayName())
		}
		return nil
	},
}

var renameCmd = &cobra.Command{
	Use:     "rename <name> <new-name>",
	Aliases: []string{"mv"},
	Short:   "Rename a sandbox",
	Args:    cobra.ExactArgs(2),
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

		newName := args[1]
		sandbox, err = client.UpdateSandbox(sandbox.ID, api.UpdateSandboxRequest{Name: &newName})
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox renamed to %q.\n", sandbox.DisplayName())
		return nil
	},
}

// formatImageAge returns a human-readable image age string (e.g. "2h ago", "3d ago").
// Returns "-" when the build timestamp is not available.
func formatImageAge(builtAt *time.Time) string {
	if builtAt == nil {
		return "-"
	}
	d := time.Since(*builtAt)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

func envTruthy(key string) bool {
	v := strings.ToLower(os.Getenv(key))
	return v == "1" || v == "true" || v == "yes"
}

func findSandboxByName(client *api.Client, name string) (*api.Sandbox, error) {
	sandboxes, err := client.ListSandboxes()
	if err != nil {
		return nil, err
	}
	for _, s := range sandboxes {
		if s.Name == name {
			return &s, nil
		}
	}
	return nil, fmt.Errorf("sandbox %q not found", name)
}
