package api

import (
	"crypto/subtle"
	"net"
	"net/http"
)

// protect wraps next with the two checks required on every route except
// /healthz: a source-IP allowlist check, then (only if that passes) a
// constant-time shared-secret token check. The IP check runs first and
// short-circuits with 403 before the token is even inspected, per the API
// contract.
func (s *Server) protect(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		remoteIP, err := sourceIP(r)
		if err != nil || !ipAllowed(remoteIP, s.allowedCIDRs) {
			writeError(w, http.StatusForbidden, ErrCodeForbiddenIP, "source IP is not in the allowed CIDR list")
			return
		}

		token := r.Header.Get("X-Router-Agent-Token")
		if subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) != 1 {
			writeError(w, http.StatusUnauthorized, ErrCodeUnauthorized, "missing or invalid X-Router-Agent-Token")
			return
		}

		next(w, r)
	}
}

func sourceIP(r *http.Request) (net.IP, error) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		// RemoteAddr had no port (unusual, but be tolerant of it rather
		// than failing open or panicking).
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return nil, errInvalidRemoteAddr
	}
	return ip, nil
}

func ipAllowed(ip net.IP, cidrs []*net.IPNet) bool {
	for _, n := range cidrs {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}
