package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var (
	gcpProjectID      string
	gcpProjectNumber  string
	gcpPoolID         string
	gcpProviderID     string
	gcpLocation       string
	gcpConfigName     string
	gcpConfigID       int
	gcpServiceAccount string
	gcpScope          string
	gcpRoles          []string
	gcpEnable         bool
	gcpDisable        bool
	gcpClearRoles     bool
	gcpFormat         string
)

func init() {
	rootCmd.AddCommand(gcpCmd)

	gcpCmd.AddCommand(gcpConfigsCmd)
	gcpCmd.AddCommand(gcpConfigCmd)
	gcpCmd.AddCommand(gcpConfigureCmd)
	gcpCmd.AddCommand(gcpSetupCmd)

	gcpConfigCmd.AddCommand(gcpConfigCreateCmd)
	gcpConfigCmd.AddCommand(gcpConfigUpdateCmd)
	gcpConfigCmd.AddCommand(gcpConfigDeleteCmd)
	gcpConfigCmd.AddCommand(gcpConfigSetupCmd)

	for _, cmd := range []*cobra.Command{gcpConfigCreateCmd, gcpConfigUpdateCmd} {
		cmd.Flags().StringVar(&gcpProjectID, "project-id", "", "GCP project ID")
		cmd.Flags().StringVar(&gcpProjectNumber, "project-number", "", "GCP project number")
		cmd.Flags().StringVar(&gcpPoolID, "pool", "", "Workload Identity Pool ID")
		cmd.Flags().StringVar(&gcpProviderID, "provider", "", "Workload Identity Provider ID")
		cmd.Flags().StringVar(&gcpLocation, "location", "global", "Workload Identity location (must be global)")
	}

	gcpConfigureCmd.Flags().StringVar(&gcpConfigName, "config", "", "GCP identity config name or ID")
	gcpConfigureCmd.Flags().StringVar(&gcpServiceAccount, "service-account", "", "Service account email to impersonate")
	gcpConfigureCmd.Flags().StringVar(&gcpScope, "scope", "user", "Principal scope: user or sandbox")
	gcpConfigureCmd.Flags().StringArrayVar(&gcpRoles, "role", nil, "Project IAM role to grant to the service account; may be repeated")
	gcpConfigureCmd.Flags().BoolVar(&gcpEnable, "enable", false, "Enable GCP credential injection")
	gcpConfigureCmd.Flags().BoolVar(&gcpDisable, "disable", false, "Disable GCP credential injection")
	gcpConfigureCmd.Flags().BoolVar(&gcpClearRoles, "clear-roles", false, "Clear configured project role hints")

	gcpSetupCmd.Flags().StringVar(&gcpFormat, "format", "shell", "Output format: shell or json")
	gcpConfigSetupCmd.Flags().StringVar(&gcpFormat, "format", "shell", "Output format: shell or json")
}

var gcpCmd = &cobra.Command{
	Use:   "gcp",
	Short: "Configure GCP Workload Identity Federation",
}

var gcpConfigsCmd = &cobra.Command{
	Use:   "configs",
	Short: "List GCP identity configs",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		configs, err := client.ListGcpOidcConfigs()
		if err != nil {
			return err
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "ID\tNAME\tPROJECT\tDEFAULT_SA\tPOOL\tPROVIDER\tSANDBOXES")
		for _, config := range configs {
			project := config.ProjectID
			if project == "" {
				project = "-"
			}
			fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\t%s\t%d\n",
				config.ID,
				config.Name,
				project,
				gcpValueOrDash(config.DefaultServiceAccountEmail),
				config.WorkloadIdentityPoolID,
				config.WorkloadIdentityProviderID,
				config.SandboxCount,
			)
		}
		w.Flush()
		return nil
	},
}

var gcpConfigCmd = &cobra.Command{
	Use:   "config",
	Short: "Create, update, delete, or inspect GCP identity configs",
}

var gcpConfigCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a reusable GCP identity config",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if strings.TrimSpace(gcpProjectNumber) == "" || strings.TrimSpace(gcpPoolID) == "" || strings.TrimSpace(gcpProviderID) == "" {
			return fmt.Errorf("--project-number, --pool, and --provider are required")
		}
		if err := validateGcpLocation(); err != nil {
			return err
		}
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		config, err := client.CreateGcpOidcConfig(gcpConfigRequest(args[0]))
		if err != nil {
			return err
		}
		fmt.Printf("GCP identity config %q created (id: %d).\n", config.Name, config.ID)
		printGcpConfigSetup(config)
		return nil
	},
}

var gcpConfigUpdateCmd = &cobra.Command{
	Use:   "update <name-or-id>",
	Short: "Update a reusable GCP identity config",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := validateGcpLocation(); err != nil {
			return err
		}
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		config, err := findGcpConfig(client, args[0])
		if err != nil {
			return err
		}
		updated, err := client.UpdateGcpOidcConfig(config.ID, gcpConfigUpdateRequest(cmd, config))
		if err != nil {
			return err
		}
		fmt.Printf("GCP identity config %q updated.\n", updated.Name)
		printGcpConfigSetup(updated)
		return nil
	},
}

var gcpConfigDeleteCmd = &cobra.Command{
	Use:   "delete <name-or-id>",
	Short: "Delete a GCP identity config",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		config, err := findGcpConfig(client, args[0])
		if err != nil {
			return err
		}
		if err := client.DeleteGcpOidcConfig(config.ID); err != nil {
			return err
		}
		fmt.Printf("GCP identity config %q deleted.\n", config.Name)
		return nil
	},
}

var gcpConfigSetupCmd = &cobra.Command{
	Use:   "setup <name-or-id>",
	Short: "Print general GCP setup commands for a config",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		config, err := findGcpConfig(client, args[0])
		if err != nil {
			return err
		}
		fullConfig, err := client.GetGcpOidcConfig(config.ID)
		if err != nil {
			return err
		}
		return printSetupOutput(client, fullConfig.Setup)
	},
}

var gcpConfigureCmd = &cobra.Command{
	Use:   "configure <sandbox>",
	Short: "Assign GCP identity config and service account to a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if gcpEnable && gcpDisable {
			return fmt.Errorf("--enable and --disable are mutually exclusive")
		}
		if gcpScope != "sandbox" && gcpScope != "user" {
			return fmt.Errorf("--scope must be sandbox or user")
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		req := api.UpdateGcpIdentityRequest{}
		if gcpDisable {
			enabled := false
			req.GCPOIDCEnabled = &enabled
		} else if gcpEnable || anyFlagChanged(cmd, "config", "service-account", "scope", "role") {
			enabled := true
			req.GCPOIDCEnabled = &enabled
		}
		if cmd.Flags().Changed("config") {
			config, err := findGcpConfig(client, gcpConfigName)
			if err != nil {
				return err
			}
			req.GCPOIDCConfigID = &config.ID
		}
		if cmd.Flags().Changed("service-account") {
			serviceAccount := strings.TrimSpace(gcpServiceAccount)
			req.GCPServiceAccountEmail = &serviceAccount
		}
		if cmd.Flags().Changed("scope") {
			scope := strings.TrimSpace(gcpScope)
			req.GCPPrincipalScope = &scope
		}
		if cmd.Flags().Changed("role") || gcpClearRoles {
			roles := cleanStringList(gcpRoles)
			req.GCPRoles = &roles
		}

		response, err := client.UpdateSandboxGcpIdentity(sandbox.ID, req)
		if err != nil {
			return err
		}

		fmt.Printf("GCP identity updated for sandbox %q.\n", response.Sandbox.Name)
		if len(response.Setup.Missing) > 0 {
			fmt.Printf("Missing: %s\n", strings.Join(response.Setup.Missing, ", "))
		}
		if response.Setup.Principal != "" {
			fmt.Printf("Principal: %s\n", response.Setup.Principal)
		}
		return nil
	},
}

var gcpSetupCmd = &cobra.Command{
	Use:   "setup <sandbox>",
	Short: "Print sandbox-specific GCP setup commands",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}
		setup, err := client.SandboxGcpOidcSetup(sandbox.ID)
		if err != nil {
			return err
		}
		return printSetupOutput(client, setup)
	},
}

func gcpConfigRequest(name string) api.GcpOidcConfigRequest {
	location := strings.TrimSpace(gcpLocation)
	if location == "" {
		location = "global"
	}

	return api.GcpOidcConfigRequest{
		Name:                       strings.TrimSpace(name),
		ProjectID:                  strings.TrimSpace(gcpProjectID),
		ProjectNumber:              strings.TrimSpace(gcpProjectNumber),
		WorkloadIdentityPoolID:     strings.TrimSpace(gcpPoolID),
		WorkloadIdentityProviderID: strings.TrimSpace(gcpProviderID),
		WorkloadIdentityLocation:   location,
	}
}

func gcpConfigUpdateRequest(cmd *cobra.Command, config *api.GcpOidcConfig) api.GcpOidcConfigRequest {
	req := api.GcpOidcConfigRequest{
		Name:                       config.Name,
		ProjectID:                  config.ProjectID,
		ProjectNumber:              config.ProjectNumber,
		WorkloadIdentityPoolID:     config.WorkloadIdentityPoolID,
		WorkloadIdentityProviderID: config.WorkloadIdentityProviderID,
		WorkloadIdentityLocation:   config.WorkloadIdentityLocation,
	}
	if cmd.Flags().Changed("project-id") {
		req.ProjectID = strings.TrimSpace(gcpProjectID)
	}
	if cmd.Flags().Changed("project-number") {
		req.ProjectNumber = strings.TrimSpace(gcpProjectNumber)
	}
	if cmd.Flags().Changed("pool") {
		req.WorkloadIdentityPoolID = strings.TrimSpace(gcpPoolID)
	}
	if cmd.Flags().Changed("provider") {
		req.WorkloadIdentityProviderID = strings.TrimSpace(gcpProviderID)
	}
	if cmd.Flags().Changed("location") {
		req.WorkloadIdentityLocation = strings.TrimSpace(gcpLocation)
	}
	return req
}

func validateGcpLocation() error {
	location := strings.TrimSpace(gcpLocation)
	if location == "" || location == "global" {
		return nil
	}
	return fmt.Errorf("GCP Workload Identity Federation pools use --location=global")
}

func findGcpConfig(client *api.Client, nameOrID string) (*api.GcpOidcConfig, error) {
	if id, err := strconv.Atoi(nameOrID); err == nil {
		return client.GetGcpOidcConfig(id)
	}

	configs, err := client.ListGcpOidcConfigs()
	if err != nil {
		return nil, err
	}
	for _, config := range configs {
		if config.Name == nameOrID {
			return &config, nil
		}
	}
	return nil, fmt.Errorf("GCP identity config %q not found", nameOrID)
}

func printSetupOutput(client *api.Client, setup *api.GcpOidcSetup) error {
	if setup == nil {
		return fmt.Errorf("setup data is unavailable")
	}
	switch gcpFormat {
	case "json":
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(setup)
	case "shell":
		printServer(client)
		if len(setup.Missing) > 0 {
			fmt.Fprintf(os.Stderr, "Missing: %s\n", strings.Join(setup.Missing, ", "))
		}
		if setup.Shell == "" {
			return fmt.Errorf("setup commands are unavailable until the config and sandbox assignment are complete")
		}
		fmt.Println(setup.Shell)
		return nil
	default:
		return fmt.Errorf("--format must be shell or json")
	}
}

func printGcpConfigSetup(config *api.GcpOidcConfig) {
	fmt.Printf("Project: %s (%s)\n", gcpValueOrDash(config.ProjectID), config.ProjectNumber)
	if config.DefaultServiceAccountEmail != "" {
		fmt.Printf("Default service account: %s\n", config.DefaultServiceAccountEmail)
	}
	if config.Setup != nil && config.Setup.Audience != "" {
		fmt.Printf("Audience: %s\n", config.Setup.Audience)
	}
}

func anyFlagChanged(cmd *cobra.Command, names ...string) bool {
	for _, name := range names {
		if cmd.Flags().Changed(name) {
			return true
		}
	}
	return false
}

func cleanStringList(values []string) []string {
	var result []string
	seen := map[string]bool{}
	for _, value := range values {
		for _, part := range strings.Split(value, ",") {
			item := strings.TrimSpace(part)
			if item == "" || seen[item] {
				continue
			}
			seen[item] = true
			result = append(result, item)
		}
	}
	return result
}

func gcpValueOrDash(value string) string {
	if strings.TrimSpace(value) == "" {
		return "-"
	}
	return value
}
