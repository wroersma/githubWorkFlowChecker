package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"

	"github.com/ThreatFlux/githubWorkFlowChecker/pkg/common"
)

// osExit is used to make the exit function testable
var osExit = os.Exit

// fileRemove is used to make the file removal testable
var fileRemove = (*os.Root).Remove

// pathValidator is used to make path validation testable
var pathValidator = validatePath

// tempEngine provides a testable template functionality
var tempEngine = struct {
	New     func(string) *template.Template
	Parse   func(*template.Template, string) (*template.Template, error)
	Execute func(*template.Template, io.Writer, interface{}) error
}{
	New: func(name string) *template.Template {
		return template.New(name)
	},
	Parse: func(t *template.Template, text string) (*template.Template, error) {
		return t.Parse(text)
	},
	Execute: func(t *template.Template, wr io.Writer, data interface{}) error {
		return t.Execute(wr, data)
	},
}

const (
	workflowTemplate = `name: Workflow {{.Number}}

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    {{range .Actions}}
      - uses: {{.Owner}}/{{.Name}}@{{.Version}}
    {{end}}
`
	maxWorkflowCount = 1000 // Maximum number of workflows allowed
	maxPathLength    = 255  // Maximum path length
)

type Action struct {
	Owner   string
	Name    string
	Version string
}

type WorkflowData struct {
	Number  int
	Actions []Action
}

var commonActions = []Action{
	{Owner: "actions", Name: "checkout", Version: "v4"},
	{Owner: "actions", Name: "setup-node", Version: "v4"},
	{Owner: "actions", Name: "setup-python", Version: "v5"},
	{Owner: "actions", Name: "setup-go", Version: "v5"},
	{Owner: "actions", Name: "cache", Version: "v3"},
	{Owner: "actions", Name: "upload-artifact", Version: "v4"},
	{Owner: "actions", Name: "download-artifact", Version: "v4"},
	{Owner: "docker", Name: "build-push-action", Version: "v5"},
	{Owner: "docker", Name: "login-action", Version: "v3"},
	{Owner: "docker", Name: "metadata-action", Version: "v5"},
}

// validatePath checks if the given path is safe to use
func validatePath(base, path string) error {
	// Check for path length
	if len(path) > maxPathLength {
		return fmt.Errorf(common.ErrPathExceedsMaxLength, maxPathLength)
	}

	// Use common path validation utility
	options := common.PathValidationOptions{
		AllowNonExistent: true,
		CheckSymlinks:    true,
	}
	return common.ValidatePath(base, path, options)
}

// SysOutCall handling for os.Stdout.Sync() call
// This is a no-op in test environments to avoid "bad file descriptor" errors
var inTestMode = false

func SysOutCall() {
	if !inTestMode {
		_ = os.Stdout.Sync()
	}
}

func main() {
	if len(os.Args) != 3 {
		fmt.Println("Usage: go run generate-test-data.go <output-dir> <workflow-count>")
		SysOutCall()
		osExit(1)
		return
	}

	// Parse workflow count first to avoid path validation errors
	count, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Printf(common.ErrInvalidTestParameters+"\n", "workflow count: "+err.Error())
		SysOutCall()
		osExit(1)
		return
	}

	if count <= 0 {
		fmt.Println(common.ErrWorkflowCountMustBePositive)
		SysOutCall()
		osExit(1)
		return
	}

	if count > maxWorkflowCount {
		fmt.Printf(common.ErrWorkflowCountExceedsLimit+"\n", maxWorkflowCount)
		SysOutCall()
		osExit(1)
		return
	}

	outputDir := os.Args[1] // Don't clean the path before validation

	// Get temporary directory as base for path validation
	tempDir := os.TempDir()

	// First validate the output directory path
	if err := validatePath(tempDir, outputDir); err != nil {
		fmt.Printf("invalid directory path: %v\n", err)
		SysOutCall()
		osExit(1)
		return
	}

	// Clean the path after validation
	outputDir = filepath.Clean(outputDir)

	// Anchor output operations inside the system's temporary directory.
	workflowDir := filepath.Join(outputDir, ".github", "workflows")
	workflowRoot, err := openWorkflowRoot(tempDir, workflowDir)
	if err != nil {
		fmt.Printf("error creating directories: %v\n", err)
		SysOutCall()
		osExit(1)
		return
	}
	defer func() { _ = workflowRoot.Close() }()

	const dummyFile = ".gitkeep"
	if err := writeWorkflowFile(workflowRoot, dummyFile, nil, 0750); err != nil {
		fmt.Printf("error creating directories: %v\n", err)
		SysOutCall()
		osExit(1)
		return
	}

	// Remove the dummy file
	if err := fileRemove(workflowRoot, dummyFile); err != nil {
		fmt.Printf(common.ErrCouldNotRemoveDummyFile+"\n", err)
	}

	// Parse template
	tmpl := tempEngine.New("workflow").Option("missingkey=error")
	tmpl, err = tempEngine.Parse(tmpl, workflowTemplate)
	if err != nil {
		fmt.Printf("error generating test data: %v\n", err)
		SysOutCall()
		osExit(1)
		return
	}

	// Generate workflow files
	// workflowDir is already defined above
	successCount := 0

	// Keep track of used actions to avoid duplicates
	usedActions := make(map[string]bool)

	for i := 1; i <= count; i++ {
		// Select 3-5 actions for each workflow (including checkout)
		actionCount := 2 + (i % 3) // 2-4 additional actions + checkout = 3-5 total
		actions := make([]Action, 0, actionCount+1)

		// Always add checkout as first action
		actions = append(actions, commonActions[0]) // checkout action
		usedActions[fmt.Sprintf("%s/%s@%s", commonActions[0].Owner, commonActions[0].Name, commonActions[0].Version)] = true

		// Add remaining actions, skipping checkout and avoiding duplicates
		for j := 0; len(actions) < actionCount+1; j++ {
			actionIndex := 1 + ((i + j) % (len(commonActions) - 1)) // Skip index 0 (checkout)
			action := commonActions[actionIndex]
			key := fmt.Sprintf("%s/%s@%s", action.Owner, action.Name, action.Version)
			if !usedActions[key] {
				actions = append(actions, action)
				usedActions[key] = true
			}
		}

		data := WorkflowData{
			Number:  i,
			Actions: actions,
		}

		filename := fmt.Sprintf("workflow-%d.yml", i)

		// Validate the file path
		if err := validatePath(outputDir, filepath.Join(workflowDir, filename)); err != nil {
			fmt.Printf("invalid file path: %v\n", err)
			SysOutCall()
			osExit(1)
			return
		}

		// Use a buffer to execute the template
		var buffer strings.Builder
		if err := tempEngine.Execute(tmpl, &buffer, data); err != nil {
			fmt.Printf("error generating test data: %v\n", err)
			SysOutCall()
			osExit(1)
			return
		}

		if err := writeWorkflowFile(workflowRoot, filename, []byte(buffer.String()), 0400); err != nil {
			fmt.Printf("error creating destination file: %v\n", err)
			SysOutCall()
			osExit(1)
			return
		}

		successCount++
		// Clear used actions for the next workflow
		usedActions = make(map[string]bool)
	}

	fmt.Printf("Generated %d workflow files in %s\n", successCount, workflowDir)
	SysOutCall()
}

func openWorkflowRoot(tempDir, workflowDir string) (*os.Root, error) {
	destination, err := filepath.Abs(workflowDir)
	if err != nil {
		return nil, err
	}
	relative, err := filepath.Rel(tempDir, destination)
	if err != nil {
		return nil, err
	}
	tempRoot, err := os.OpenRoot(tempDir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tempRoot.Close() }()

	if err := tempRoot.MkdirAll(relative, 0750); err != nil {
		return nil, err
	}
	return tempRoot.OpenRoot(relative)
}

func writeWorkflowFile(root *os.Root, name string, data []byte, mode os.FileMode) (err error) {
	if info, err := root.Stat(name); err == nil {
		if info.Mode().Perm()&0200 == 0 {
			return errors.New("file exists and is read-only")
		}
	} else if !os.IsNotExist(err) {
		return err
	}

	tempName := name + ".tmp"
	file, err := root.OpenFile(tempName, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = root.Remove(tempName)
		}
	}()

	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return root.Rename(tempName, name)
}
