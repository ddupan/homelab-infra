package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/oauth2"
)

func TestStateBoundToCookieSingleUseAndExpiry(t *testing.T) {
	a := &app{pending: map[string]pending{"valid": {Challenge: "challenge", Expires: time.Now().Add(time.Minute)}, "expired": {Expires: time.Now().Add(-time.Minute)}}}
	request := func(state, cookie string) *http.Request {
		r := httptest.NewRequest("GET", "https://login.example/callback?state="+state, nil)
		if cookie != "" {
			r.AddCookie(&http.Cookie{Name: cookieName, Value: cookie})
		}
		return r
	}
	for _, r := range []*http.Request{request("valid", ""), request("valid", "other"), request("expired", "expired")} {
		if _, err := a.take(r); err == nil {
			t.Fatal("invalid state accepted")
		}
	}
	if p, err := a.take(request("valid", "valid")); err != nil || p.Challenge != "challenge" {
		t.Fatal("valid state rejected")
	}
	if _, err := a.take(request("valid", "valid")); err == nil {
		t.Fatal("replayed state accepted")
	}
}
func TestConsentRejectsPrivilegeExpansionAndFiltersClaims(t *testing.T) {
	f := flowRequest{Subject: "human:known", Scopes: []string{"openid", "email"}, Context: claims{Username: "alice", Email: "alice@example.org", EmailVerified: true, Groups: []string{"operators"}}}
	s, err := consentSession(f)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s["groups"]; ok {
		t.Fatal("groups leaked without scope")
	}
	if _, ok := s["preferred_username"]; ok {
		t.Fatal("profile leaked without scope")
	}
	for _, scope := range []string{"admin", "offline_access", "unknown"} {
		bad := f
		bad.Scopes = append([]string{"openid"}, scope)
		if _, err := consentSession(bad); err == nil {
			t.Fatalf("accepted %s", scope)
		}
	}
	f.Audience = []string{"other-service"}
	if _, err := consentSession(f); err == nil {
		t.Fatal("unexpected audience accepted")
	}
	f.Audience = nil
	f.Context.EmailVerified = false
	if _, err := consentSession(f); err == nil {
		t.Fatal("unverified email accepted")
	}
}
func TestLoginValidatesClientAndUsesPKCEAndNonce(t *testing.T) {
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"client": map[string]string{"client_id": r.URL.Query().Get("login_challenge")}})
	}))
	defer admin.Close()
	a := &app{admin: admin.URL, client: admin.Client(), allowed: map[string]bool{"gitea": true}, pending: map[string]pending{}, oauth: oauth2.Config{ClientID: "hydra-login", RedirectURL: "https://login.example/callback", Endpoint: oauth2.Endpoint{AuthURL: "https://upstream.example/authorize"}}}
	w := httptest.NewRecorder()
	a.handler().ServeHTTP(w, httptest.NewRequest("GET", "https://login.example/login?login_challenge=rogue", nil))
	if w.Code != 403 {
		t.Fatal("unknown client accepted")
	}
	w = httptest.NewRecorder()
	a.handler().ServeHTTP(w, httptest.NewRequest("GET", "https://login.example/login?login_challenge=gitea", nil))
	if w.Code != 303 {
		t.Fatalf("status %d", w.Code)
	}
	u, _ := url.Parse(w.Header().Get("Location"))
	q := u.Query()
	if q.Get("code_challenge_method") != "S256" || q.Get("code_challenge") == "" || q.Get("nonce") == "" || q.Get("state") == "" {
		t.Fatal("missing protocol binding")
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteLaxMode || cookies[0].Value != q.Get("state") {
		t.Fatal("unsafe cookie")
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("missing cache protection")
	}
}
func TestHydraRedirectCannotLeaveTrustedOrigin(t *testing.T) {
	for _, target := range []string{"https://evil.example/oauth2/auth", "https://hydra.example@evil.example/oauth2/auth", "https://hydra.example/other"} {
		admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			json.NewEncoder(w).Encode(map[string]string{"redirect_to": target})
		}))
		a := &app{admin: admin.URL, public: "https://hydra.example", client: admin.Client()}
		w := httptest.NewRecorder()
		a.accept(w, httptest.NewRequest("GET", "https://login.example/login", nil), "login", "challenge", map[string]string{"subject": "human:test"})
		if w.Code != 502 || strings.Contains(w.Header().Get("Location"), "evil") {
			t.Fatal("untrusted redirect accepted")
		}
		admin.Close()
	}
}
