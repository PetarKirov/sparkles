package greeter

import "testing"

func TestGreet(t *testing.T) {
	got := Greet("workspace")
	want := "Hello, workspace!"
	if got != want {
		t.Errorf("Greet(%q) = %q, want %q", "workspace", got, want)
	}
}
