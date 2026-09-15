package dispatch

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"router-agent/internal/sshclient"
)

// fakeExecer is a scripted stand-in for the SSH layer so dispatch.go's
// command-string building and result mapping can be tested without a live
// router.
type fakeExecer struct {
	wantCmd string
	stdout  string
	stderr  string
	exit    int
	err     error
}

func (f *fakeExecer) Exec(_ context.Context, cmd string) (string, string, int, error) {
	if f.wantCmd != "" && cmd != f.wantCmd {
		return "", "", 0, fmt.Errorf("unexpected command %q, want %q", cmd, f.wantCmd)
	}
	return f.stdout, f.stderr, f.exit, f.err
}

func TestAllow_BuildsExpectedCommandAndParsesSuccess(t *testing.T) {
	f := &fakeExecer{wantCmd: "allow 192.168.1.146 30", stdout: "OK allow 192.168.1.146 30m\n", exit: 0}
	d := New(f)

	res, err := d.Allow(context.Background(), "192.168.1.146", 30)
	if err != nil {
		t.Fatalf("Allow() error = %v", err)
	}
	if res.IP != "192.168.1.146" || res.TimeoutMin != 30 {
		t.Errorf("Allow() = %#v, want ip=192.168.1.146 timeout=30", res)
	}
}

func TestAllow_PermanentTimeoutZero(t *testing.T) {
	f := &fakeExecer{wantCmd: "allow 10.0.0.1 0", stdout: "OK allow 10.0.0.1 0\n", exit: 0}
	d := New(f)

	res, err := d.Allow(context.Background(), "10.0.0.1", 0)
	if err != nil {
		t.Fatalf("Allow() error = %v", err)
	}
	if res.TimeoutMin != 0 {
		t.Errorf("Allow() TimeoutMin = %d, want 0", res.TimeoutMin)
	}
}

func TestBlock_BuildsExpectedCommand(t *testing.T) {
	f := &fakeExecer{wantCmd: "block 192.168.1.146", stdout: "OK block 192.168.1.146\n", exit: 0}
	d := New(f)

	res, err := d.Block(context.Background(), "192.168.1.146")
	if err != nil {
		t.Fatalf("Block() error = %v", err)
	}
	if res.IP != "192.168.1.146" {
		t.Errorf("Block() = %#v", res)
	}
}

func TestBlock_NotPresentIsIdempotentSuccess(t *testing.T) {
	f := &fakeExecer{wantCmd: "block 10.0.0.9", stdout: "OK block 10.0.0.9 (not present)\n", exit: 0}
	d := New(f)

	res, err := d.Block(context.Background(), "10.0.0.9")
	if err != nil {
		t.Fatalf("Block() error = %v, want success for idempotent not-present block", err)
	}
	if res.IP != "10.0.0.9" {
		t.Errorf("Block() = %#v", res)
	}
}

func TestStatus_TablePresent(t *testing.T) {
	f := &fakeExecer{wantCmd: "status", stdout: "OK table=ip captive present\n", exit: 0}
	d := New(f)

	res, err := d.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() error = %v", err)
	}
	if !res.TablePresent {
		t.Error("Status().TablePresent = false, want true")
	}
}

func TestStatus_TableMissingIsLegitimateFailure(t *testing.T) {
	f := &fakeExecer{wantCmd: "status", stderr: "ERR table missing\n", exit: 1}
	d := New(f)

	res, err := d.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() error = %v, want a well-formed result for documented 'table missing' case", err)
	}
	if res.TablePresent {
		t.Error("Status().TablePresent = true, want false")
	}
}

func TestStatus_UnexpectedOutputIsCommandFailed(t *testing.T) {
	f := &fakeExecer{wantCmd: "status", stdout: "something unexpected\n", exit: 0}
	d := New(f)

	_, err := d.Status(context.Background())
	assertKind(t, err, KindRouterCommandFailed)
}

func TestList_ReturnsRawStdout(t *testing.T) {
	f := &fakeExecer{wantCmd: "list", stdout: `{"nftables":[]}`, exit: 0}
	d := New(f)

	raw, err := d.List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if raw != `{"nftables":[]}` {
		t.Errorf("List() = %q", raw)
	}
}

func TestRun_MapsTransportErrorsToKind(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want Kind
	}{
		{"timeout", fmt.Errorf("wrap: %w", sshclient.ErrTimeout), KindRouterTimeout},
		{"unreachable", fmt.Errorf("wrap: %w", sshclient.ErrUnreachable), KindRouterUnreachable},
		{"other", errors.New("boom"), KindRouterCommandFailed},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := &fakeExecer{err: tc.err}
			d := New(f)
			_, err := d.Allow(context.Background(), "10.0.0.1", 30)
			assertKind(t, err, tc.want)
		})
	}
}

func assertKind(t *testing.T, err error, want Kind) {
	t.Helper()
	if err == nil {
		t.Fatalf("error = nil, want Kind %s", want)
	}
	var derr *Error
	if !errors.As(err, &derr) {
		t.Fatalf("error = %v, want *dispatch.Error", err)
	}
	if derr.Kind != want {
		t.Errorf("Kind = %s, want %s", derr.Kind, want)
	}
}
