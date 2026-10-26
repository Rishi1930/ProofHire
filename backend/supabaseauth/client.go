package supabaseauth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

var (
	ErrUnauthenticated = errors.New("request is not authenticated")
	ErrForbidden       = errors.New("workspace access is not permitted")
	ErrUnavailable     = errors.New("authentication service is unavailable")
)

type User struct {
	ID string `json:"id"`
}

type Verifier interface {
	VerifyAccessToken(ctx context.Context, accessToken string) (User, error)
}

type Client struct {
	baseURL    string
	anonKey    string
	httpClient *http.Client
}

func NewClient(config config.Config) *Client {
	return NewClientWithHTTPClient(config, &http.Client{Timeout: 10 * time.Second})
}

func NewClientWithHTTPClient(config config.Config, httpClient *http.Client) *Client {
	return &Client{
		baseURL:    strings.TrimRight(config.SupabaseURL, "/"),
		anonKey:    config.SupabaseAnonKey,
		httpClient: httpClient,
	}
}

func (client *Client) VerifyAccessToken(ctx context.Context, accessToken string) (User, error) {
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		client.baseURL+"/auth/v1/user",
		nil,
	)
	if err != nil {
		return User{}, ErrUnavailable
	}
	request.Header.Set("apikey", client.anonKey)
	request.Header.Set("Authorization", "Bearer "+accessToken)

	response, err := client.httpClient.Do(request)
	if err != nil {
		return User{}, ErrUnavailable
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized ||
		response.StatusCode == http.StatusForbidden {
		return User{}, ErrUnauthenticated
	}
	if response.StatusCode != http.StatusOK {
		return User{}, ErrUnavailable
	}

	var user User
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&user); err != nil {
		return User{}, ErrUnavailable
	}
	if strings.TrimSpace(user.ID) == "" {
		return User{}, fmt.Errorf("%w: Supabase user response did not include an ID", ErrUnavailable)
	}
	return user, nil
}

func (client *Client) GetWorkspaceRole(
	ctx context.Context,
	accessToken string,
	userID string,
	workspaceID string,
) (string, error) {
	if !isUUID(userID) || !isUUID(workspaceID) {
		return "", ErrForbidden
	}

	targetURL := client.baseURL + "/rest/v1/workspace_members"
	requestURL, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		targetURL,
		nil,
	)
	if err != nil {
		return "", ErrUnavailable
	}
	query := requestURL.URL.Query()
	query.Set("select", "role")
	query.Set("user_id", "eq."+userID)
	query.Set("workspace_id", "eq."+workspaceID)
	query.Set("limit", "1")
	requestURL.URL.RawQuery = query.Encode()
	requestURL.Header.Set("apikey", client.anonKey)
	requestURL.Header.Set("Authorization", "Bearer "+accessToken)

	response, err := client.httpClient.Do(requestURL)
	if err != nil {
		return "", ErrUnavailable
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized {
		return "", ErrUnauthenticated
	}
	if response.StatusCode == http.StatusForbidden {
		return "", ErrForbidden
	}
	if response.StatusCode != http.StatusOK {
		return "", ErrUnavailable
	}

	var memberships []struct {
		Role string `json:"role"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&memberships); err != nil {
		return "", ErrUnavailable
	}
	if len(memberships) == 0 {
		return "", ErrForbidden
	}
	if len(memberships) != 1 || !isWorkspaceRole(memberships[0].Role) {
		return "", ErrUnavailable
	}
	return memberships[0].Role, nil
}

func isWorkspaceRole(value string) bool {
	switch value {
	case "owner", "admin", "recruiter", "viewer":
		return true
	default:
		return false
	}
}

func isUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		switch index {
		case 8, 13, 18, 23:
			if character != '-' {
				return false
			}
		default:
			if !((character >= '0' && character <= '9') ||
				(character >= 'a' && character <= 'f') ||
				(character >= 'A' && character <= 'F')) {
				return false
			}
		}
	}
	return true
}
