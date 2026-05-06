package cmd

import (
	"fmt"
	"sort"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var (
	projectPath         string
	projectImage        string
	projectTailscale    bool
	projectNoVNC        bool
	projectVNCGeometry  string
	projectVNCDepth     int
	projectNoDocker     bool
	projectSMB          bool
	projectSSHStartTmux bool
)

func init() {
	rootCmd.AddCommand(projectCmd)
	projectCmd.AddCommand(projectListCmd)
	projectCmd.AddCommand(projectCreateCmd)
	projectCmd.AddCommand(projectDeleteCmd)

	projectCreateCmd.Flags().StringVar(&projectPath, "path", "", "Project subdir mounted as both $HOME and /persisted")
	projectCreateCmd.Flags().StringVar(&projectImage, "image", "ghcr.io/thieso2/sandcastle-sandbox:latest", "Default container image")
	projectCreateCmd.Flags().BoolVar(&projectTailscale, "tailscale", false, "Enable Tailscale by default")
	projectCreateCmd.Flags().BoolVar(&projectNoVNC, "no-vnc", false, "Disable VNC by default")
	projectCreateCmd.Flags().StringVar(&projectVNCGeometry, "vnc-geometry", "", "Default VNC screen resolution")
	projectCreateCmd.Flags().IntVar(&projectVNCDepth, "vnc-depth", 0, "Default VNC color depth")
	projectCreateCmd.Flags().BoolVar(&projectNoDocker, "no-docker", false, "Disable Docker by default")
	projectCreateCmd.Flags().BoolVar(&projectSMB, "smb", false, "Enable SMB by default")
	projectCreateCmd.Flags().BoolVar(&projectSSHStartTmux, "ssh-start-tmux", true, "Start tmux on SSH login by default")
}

var projectCmd = &cobra.Command{
	Use:   "project",
	Short: "Manage reusable project presets",
}

var projectListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List saved projects",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		projects, err := client.ListProjects()
		if err != nil {
			return err
		}
		sort.Slice(projects, func(i, j int) bool { return projects[i].Name < projects[j].Name })

		if len(projects) == 0 {
			fmt.Println("No projects saved.")
			return nil
		}

		w := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tPATH\tIMAGE\tSERVICES")
		for _, p := range projects {
			services := []string{}
			if p.DockerEnabled {
				services = append(services, "docker")
			}
			if p.VNCEnabled {
				services = append(services, "vnc")
			}
			if p.Tailscale {
				services = append(services, "tailscale")
			}
			if p.SMBEnabled {
				services = append(services, "smb")
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", p.Name, p.Path, p.Image, joinCSV(services))
		}
		return w.Flush()
	},
}

var projectCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a reusable project preset",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if projectPath == "" {
			return fmt.Errorf("--path is required")
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}

		project, err := client.CreateProject(api.CreateProjectRequest{
			Name:          args[0],
			Path:          projectPath,
			Image:         projectImage,
			Tailscale:     projectTailscale,
			VNCEnabled:    !projectNoVNC,
			VNCGeometry:   projectVNCGeometry,
			VNCDepth:      projectVNCDepth,
			DockerEnabled: !projectNoDocker,
			SMBEnabled:    projectSMB,
			SSHStartTmux:  projectSSHStartTmux,
		})
		if err != nil {
			return err
		}

		fmt.Printf("Project %q created (%s).\n", project.Name, project.Path)
		return nil
	},
}

var projectDeleteCmd = &cobra.Command{
	Use:   "delete <id>",
	Short: "Delete a project preset",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		id, err := parseID(args[0])
		if err != nil {
			return err
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		return client.DestroyProject(id)
	},
}

func joinCSV(items []string) string {
	if len(items) == 0 {
		return "-"
	}
	out := items[0]
	for i := 1; i < len(items); i++ {
		out += "," + items[i]
	}
	return out
}

func parseID(s string) (int, error) {
	var id int
	_, err := fmt.Sscanf(s, "%d", &id)
	if err != nil {
		return 0, fmt.Errorf("invalid id %q", s)
	}
	return id, nil
}
