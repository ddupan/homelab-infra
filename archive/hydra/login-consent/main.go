// Login/Consent adapter for a single trusted upstream and first-party clients.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"golang.org/x/oauth2"
)

const cookieName = "__Host-hydra-login"

type pending struct {
	Challenge, Nonce, Verifier string
	Expires                    time.Time
}
type claims struct {
	Username      string   `json:"preferred_username"`
	Email         string   `json:"email"`
	EmailVerified bool     `json:"email_verified"`
	Name          string   `json:"name"`
	Groups        []string `json:"groups"`
}
type flowRequest struct {
	Client struct {
		ID string `json:"client_id"`
	} `json:"client"`
	Subject  string   `json:"subject"`
	Scopes   []string `json:"requested_scope"`
	Audience []string `json:"requested_access_token_audience"`
	Context  claims   `json:"context"`
}
type app struct {
	admin, public string
	client        *http.Client
	oauth         oauth2.Config
	verifier      *oidc.IDTokenVerifier
	allowed       map[string]bool
	mu            sync.Mutex
	pending       map[string]pending
}

func required(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("missing %s", key)
	}
	return v
}
func random() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func (a *app) api(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.admin+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return errors.New("Hydra unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Hydra status %d", resp.StatusCode)
	}
	if out != nil {
		return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
	}
	return nil
}
func (a *app) request(r *http.Request, kind, challenge string) (flowRequest, error) {
	var f flowRequest
	if challenge == "" || len(challenge) > 8192 {
		return f, errors.New("missing or invalid challenge")
	}
	err := a.api(r.Context(), http.MethodGet, "/admin/oauth2/auth/requests/"+kind+"?"+kind+"_challenge="+url.QueryEscape(challenge), nil, &f)
	if err != nil {
		return f, err
	}
	if !a.allowed[f.Client.ID] {
		return f, errors.New("client not allowed")
	}
	return f, nil
}
func (a *app) accept(w http.ResponseWriter, r *http.Request, kind, challenge string, body any) {
	var result struct {
		Redirect string `json:"redirect_to"`
	}
	if err := a.api(r.Context(), http.MethodPut, "/admin/oauth2/auth/requests/"+kind+"/accept?"+kind+"_challenge="+url.QueryEscape(challenge), body, &result); err != nil {
		fail(w, 502)
		return
	}
	// Only Hydra's own authorization endpoint can receive a challenge verifier.
	u, err := url.Parse(result.Redirect)
	p, _ := url.Parse(a.public)
	if err != nil || u.Scheme != p.Scheme || u.Host != p.Host || u.User != nil || u.Path != "/oauth2/auth" {
		fail(w, 502)
		return
	}
	http.Redirect(w, r, result.Redirect, http.StatusSeeOther)
}
func fail(w http.ResponseWriter, status int) { http.Error(w, http.StatusText(status), status) }
func (a *app) login(w http.ResponseWriter, r *http.Request) {
	challenge := r.URL.Query().Get("login_challenge")
	if _, err := a.request(r, "login", challenge); err != nil {
		fail(w, 403)
		return
	}
	state := random()
	p := pending{challenge, random(), oauth2.GenerateVerifier(), time.Now().Add(10 * time.Minute)}
	a.mu.Lock()
	for k, v := range a.pending {
		if time.Now().After(v.Expires) {
			delete(a.pending, k)
		}
	}
	if len(a.pending) >= 1024 {
		a.mu.Unlock()
		fail(w, 503)
		return
	}
	a.pending[state] = p
	a.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: state, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 600})
	http.Redirect(w, r, a.oauth.AuthCodeURL(state, oidc.Nonce(p.Nonce), oauth2.S256ChallengeOption(p.Verifier)), http.StatusSeeOther)
}
func (a *app) take(r *http.Request) (pending, error) {
	state := r.URL.Query().Get("state")
	cookie, err := r.Cookie(cookieName)
	if err != nil || state == "" || subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(state)) != 1 {
		return pending{}, errors.New("state mismatch")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	p, ok := a.pending[state]
	delete(a.pending, state)
	if !ok || time.Now().After(p.Expires) {
		return pending{}, errors.New("expired or used state")
	}
	return p, nil
}
func (a *app) callback(w http.ResponseWriter, r *http.Request) {
	p, err := a.take(r)
	if err != nil {
		fail(w, 403)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Path: "/", Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: -1})
	if r.URL.Query().Get("error") != "" || r.URL.Query().Get("code") == "" {
		fail(w, 403)
		return
	}
	ctx := oidc.ClientContext(r.Context(), a.client)
	token, err := a.oauth.Exchange(ctx, r.URL.Query().Get("code"), oauth2.VerifierOption(p.Verifier))
	if err != nil {
		fail(w, 502)
		return
	}
	raw, ok := token.Extra("id_token").(string)
	if !ok {
		fail(w, 502)
		return
	}
	id, err := a.verifier.Verify(ctx, raw)
	if err != nil || id.Nonce != p.Nonce || id.Subject == "" {
		fail(w, 403)
		return
	}
	var c claims
	if id.Claims(&c) != nil || c.Username == "" || c.Email == "" || !c.EmailVerified {
		fail(w, 403)
		return
	}
	if _, err := a.request(r, "login", p.Challenge); err != nil {
		fail(w, 403)
		return
	}
	// Stable identity is tied to the verified upstream issuer+subject, never email.
	sum := sha256.Sum256([]byte(id.Issuer + "\x00" + id.Subject))
	a.accept(w, r, "login", p.Challenge, map[string]any{"subject": "human:" + hex.EncodeToString(sum[:]), "remember": false, "context": c})
}
func consentSession(f flowRequest) (map[string]any, error) {
	if !strings.HasPrefix(f.Subject, "human:") || f.Context.Username == "" || f.Context.Email == "" || !f.Context.EmailVerified {
		return nil, errors.New("invalid identity context")
	}
	allowed := map[string]bool{"openid": true, "profile": true, "email": true, "groups": true}
	session := map[string]any{"principal_type": "human"}
	for _, scope := range f.Scopes {
		if !allowed[scope] {
			return nil, errors.New("scope not allowed")
		}
		switch scope {
		case "profile":
			session["preferred_username"] = f.Context.Username
			session["name"] = f.Context.Name
		case "email":
			session["email"] = f.Context.Email
			session["email_verified"] = true
		case "groups":
			session["groups"] = f.Context.Groups
		}
	}
	if len(f.Audience) > 0 {
		return nil, errors.New("access token audience not allowed")
	}
	return session, nil
}
func (a *app) consent(w http.ResponseWriter, r *http.Request) {
	challenge := r.URL.Query().Get("consent_challenge")
	f, err := a.request(r, "consent", challenge)
	if err != nil {
		fail(w, 403)
		return
	}
	session, err := consentSession(f)
	if err != nil {
		fail(w, 403)
		return
	}
	// Explicit policy for pre-approved first-party clients only; no generic auto-consent.
	a.accept(w, r, "consent", challenge, map[string]any{"grant_scope": f.Scopes, "remember": false, "session": map[string]any{"id_token": session}})
}
func (a *app) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("GET /login", a.login)
	mux.HandleFunc("GET /callback", a.callback)
	mux.HandleFunc("GET /consent", a.consent)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		mux.ServeHTTP(w, r)
	})
}
func main() {
	client := &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(r *http.Request, via []*http.Request) error { return http.ErrUseLastResponse }}
	issuer := required("UPSTREAM_ISSUER")
	ctx := oidc.ClientContext(context.Background(), client)
	provider, err := oidc.NewProvider(ctx, issuer)
	if err != nil {
		log.Fatal("upstream discovery failed")
	}
	clientID := required("UPSTREAM_CLIENT_ID")
	a := &app{admin: required("HYDRA_ADMIN_URL"), public: required("HYDRA_PUBLIC_URL"), client: client, allowed: map[string]bool{}, pending: map[string]pending{},
		oauth:    oauth2.Config{ClientID: clientID, ClientSecret: required("UPSTREAM_CLIENT_SECRET"), RedirectURL: required("CALLBACK_URL"), Endpoint: provider.Endpoint(), Scopes: []string{"openid", "profile", "email", "groups"}},
		verifier: provider.Verifier(&oidc.Config{ClientID: clientID})}
	for _, id := range strings.Split(required("ALLOWED_CLIENTS"), ",") {
		a.allowed[id] = true
	}
	s := http.Server{Addr: ":8080", Handler: a.handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 20 * time.Second, WriteTimeout: 45 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16384}
	log.Print("login/consent adapter listening on :8080")
	log.Fatal(s.ListenAndServe())
}
