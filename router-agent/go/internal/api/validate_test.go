package api

import "testing"

func TestValidateIPv4(t *testing.T) {
	cases := []struct {
		ip   string
		want bool
	}{
		{"192.168.1.146", true},
		{"0.0.0.0", true},
		{"255.255.255.255", true},
		{"010.0.0.1", true}, // leading zero: router's shell _validate_ip accepts this
		{"", false},
		{"192.168.1", false},
		{"192.168.1.1.1", false},
		{"192.168.1.256", false},
		{"192.168.1.-1", false},
		{"192.168.1.a", false},
		{"::1", false},
		{"192.168.1.1 ", false},
		{"192.168..1.1", false},
	}
	for _, tc := range cases {
		t.Run(tc.ip, func(t *testing.T) {
			got := ValidateIPv4(tc.ip)
			if got != tc.want {
				t.Errorf("ValidateIPv4(%q) = %v, want %v", tc.ip, got, tc.want)
			}
		})
	}
}
