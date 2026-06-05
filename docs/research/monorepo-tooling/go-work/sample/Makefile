# Workspace task runner. `go.work` only composes the dependency graph; task
# orchestration is plain `go` over package patterns. `./...` from the workspace
# root broadcasts across every `use`d member (cli + greeter).
.PHONY: build test run vet clean

build:
	go build ./...

test:
	go test ./...

run:
	go run example.com/cli

vet:
	go vet ./...

clean:
	go clean -cache
