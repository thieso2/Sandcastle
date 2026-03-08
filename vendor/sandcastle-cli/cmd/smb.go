package cmd

import (
	"fmt"
	"syscall"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	smbCmd.AddCommand(smbSetPasswordCmd)
	rootCmd.AddCommand(smbCmd)
}

var smbCmd = &cobra.Command{
	Use:   "smb",
	Short: "Manage SMB file sharing",
	Long: `Manage SMB (Samba) file sharing for your sandboxes.

SMB lets you mount your sandbox home directory or /workspace as a network drive
from macOS, Windows, or Linux. Requires Tailscale for access.

Enable SMB when creating a sandbox with --smb, then connect via:
  macOS:   smb://<tailscale-ip>/home
  Windows: \\<tailscale-ip>\home
  Linux:   mount -t cifs //<tailscale-ip>/home /mnt -o username=<you>`,
}

var smbSetPasswordCmd = &cobra.Command{
	Use:   "set-password",
	Short: "Set your SMB password for file sharing",
	Long: `Set the SMB password used to authenticate when mounting sandbox shares.

The password is stored encrypted on the server and passed to sandboxes
that have SMB enabled. All your SMB-enabled sandboxes share the same password.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		fmt.Print("New SMB password: ")
		pass1, err := term.ReadPassword(syscall.Stdin)
		fmt.Println()
		if err != nil {
			return fmt.Errorf("reading password: %w", err)
		}

		fmt.Print("Confirm SMB password: ")
		pass2, err := term.ReadPassword(syscall.Stdin)
		fmt.Println()
		if err != nil {
			return fmt.Errorf("reading password: %w", err)
		}

		if string(pass1) != string(pass2) {
			return fmt.Errorf("passwords do not match")
		}

		if len(pass1) == 0 {
			return fmt.Errorf("password cannot be empty")
		}

		if err := client.SmbSetPassword(string(pass1)); err != nil {
			return fmt.Errorf("setting SMB password: %w", err)
		}

		fmt.Println("SMB password updated. Active SMB-enabled sandboxes have been updated.")
		return nil
	},
}
