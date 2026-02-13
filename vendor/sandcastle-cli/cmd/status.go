package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(statusCmd)
}

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show system status",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		status, err := client.Status()
		if err != nil {
			return err
		}

		out, _ := json.MarshalIndent(status, "", "  ")
		fmt.Println(string(out))
		return nil
	},
}
