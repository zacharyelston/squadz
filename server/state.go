package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	pairkit "github.com/zacharyelston/pairkit/go"
)

// A Member is a paired phone and the person carrying it. Its ID is the
// PairKit device ID.
type Member struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	SquadID  string    `json:"squad_id,omitempty"`
	JoinedAt time.Time `json:"joined_at"`
}

type Squad struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	LeaderID  string    `json:"leader_id"`
	CreatedAt time.Time `json:"created_at"`
}

// Position is what a phone reports. Optional fields stay out of the JSON
// when absent: the mesh link is slow.
type Position struct {
	Latitude  float64  `json:"latitude"`
	Longitude float64  `json:"longitude"`
	Altitude  *float64 `json:"altitude,omitempty"`
	Accuracy  *float64 `json:"accuracy,omitempty"`
	Heading   *float64 `json:"heading,omitempty"`
	Speed     *float64 `json:"speed,omitempty"`
}

type fix struct {
	Position
	at time.Time
}

// State is every squad and member, saved to one JSON file on each change.
// Positions are kept in memory only: they go stale in minutes anyway.
type State struct {
	mu       sync.Mutex
	path     string
	maxSquad int
	squads   map[string]*Squad
	members  map[string]*Member
	fixes    map[string]fix
	now      func() time.Time
}

type savedState struct {
	Squads  []*Squad  `json:"squads"`
	Members []*Member `json:"members"`
}

func openState(path string, maxSquad int) (*State, error) {
	s := &State{path: path, maxSquad: maxSquad, squads: map[string]*Squad{}, members: map[string]*Member{},
		fixes: map[string]fix{}, now: time.Now}
	if path == "" {
		return s, nil
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var st savedState
	if err := json.Unmarshal(raw, &st); err != nil {
		return nil, err
	}
	for _, q := range st.Squads {
		s.squads[q.ID] = q
	}
	for _, m := range st.Members {
		s.members[m.ID] = m
	}
	return s, nil
}

func (s *State) save() error {
	if s.path == "" {
		return nil
	}
	st := savedState{Squads: []*Squad{}, Members: []*Member{}}
	for _, q := range s.squads {
		st.Squads = append(st.Squads, q)
	}
	for _, m := range s.members {
		st.Members = append(st.Members, m)
	}
	raw, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return pairkit.WriteFileAtomic(s.path, raw)
}

func refuse(status int, code, msg string) error {
	return &pairkit.Error{Status: status, Code: code, Msg: msg}
}

func cleanName(name string) (string, error) {
	name = strings.Join(strings.Fields(name), " ")
	if name == "" || len([]rune(name)) > 40 {
		return "", refuse(http.StatusBadRequest, "bad_name", "a name must be 1 to 40 characters")
	}
	return name, nil
}

// squadMembers returns a squad's members, oldest first. Caller holds mu.
func (s *State) squadMembers(squadID string) []*Member {
	var out []*Member
	for _, m := range s.members {
		if m.SquadID == squadID {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].JoinedAt.Equal(out[j].JoinedAt) {
			return out[i].JoinedAt.Before(out[j].JoinedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// place checks that a person called name may join squadID. Caller holds mu.
func (s *State) place(squadID, name string) error {
	if s.squads[squadID] == nil {
		return refuse(http.StatusGone, "squad_gone", "that squad no longer exists")
	}
	members := s.squadMembers(squadID)
	if len(members) >= s.maxSquad {
		return refuse(http.StatusConflict, "squad_full", "that squad is full")
	}
	for _, m := range members {
		if strings.EqualFold(m.Name, name) {
			return refuse(http.StatusConflict, "name_taken", "someone in that squad already uses that name")
		}
	}
	return nil
}

// AddMember records a newly paired phone. squadID "" pairs it with the
// server only; it can create a squad afterwards.
func (s *State) AddMember(id, name, squadID string) (*SquadView, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if squadID != "" {
		if err := s.place(squadID, name); err != nil {
			return nil, err
		}
	}
	s.members[id] = &Member{ID: id, Name: name, SquadID: squadID, JoinedAt: s.now().UTC()}
	return s.view(squadID), s.save()
}

// CreateSquad starts a squad led by the member, who must not be in one.
func (s *State) CreateSquad(memberID, name string) (*SquadView, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.members[memberID]
	if m == nil {
		return nil, refuse(http.StatusForbidden, "not_member", "this phone is not paired")
	}
	if m.SquadID != "" {
		return nil, refuse(http.StatusConflict, "in_squad", "leave your squad before starting another")
	}
	q := &Squad{ID: newID(), Name: name, LeaderID: m.ID, CreatedAt: s.now().UTC()}
	s.squads[q.ID] = q
	m.SquadID, m.JoinedAt = q.ID, q.CreatedAt
	return s.view(q.ID), s.save()
}

// Leave takes the member out of their squad. The longest-standing member
// left becomes leader; an empty squad is deleted. gone also forgets the
// member altogether (the phone was signed out).
func (s *State) Leave(memberID string, gone bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.members[memberID]
	if m == nil {
		return nil
	}
	squadID := m.SquadID
	m.SquadID = ""
	delete(s.fixes, memberID)
	if gone {
		delete(s.members, memberID)
	}
	if q := s.squads[squadID]; q != nil {
		if rest := s.squadMembers(squadID); len(rest) == 0 {
			delete(s.squads, squadID)
		} else if q.LeaderID == memberID {
			q.LeaderID = rest[0].ID
		}
	}
	return s.save()
}

func (s *State) Member(id string) (Member, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.members[id]
	if m == nil {
		return Member{}, false
	}
	return *m, true
}

// SquadView is a squad as its members see it.
type SquadView struct {
	ID       string       `json:"id"`
	Name     string       `json:"name"`
	LeaderID string       `json:"leader_id"`
	Members  []MemberView `json:"members"`
}

type MemberView struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s *State) view(squadID string) *SquadView {
	q := s.squads[squadID]
	if q == nil {
		return nil
	}
	v := &SquadView{ID: q.ID, Name: q.Name, LeaderID: q.LeaderID, Members: []MemberView{}}
	for _, m := range s.squadMembers(squadID) {
		v.Members = append(v.Members, MemberView{m.ID, m.Name})
	}
	return v
}

func (s *State) Squad(squadID string) *SquadView {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.view(squadID)
}

func (s *State) SetPosition(memberID string, p Position) error {
	if !(p.Latitude >= -90 && p.Latitude <= 90 && p.Longitude >= -180 && p.Longitude <= 180) {
		return refuse(http.StatusBadRequest, "bad_position", "latitude or longitude out of range")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if m := s.members[memberID]; m == nil || m.SquadID == "" {
		return refuse(http.StatusConflict, "no_squad", "join a squad before sharing your position")
	}
	s.fixes[memberID] = fix{p, s.now()}
	return nil
}

// Located is one member's last position. Age is in whole seconds by the
// server's clock, so phones need no agreement about the time of day.
type Located struct {
	MemberID string `json:"member_id"`
	Name     string `json:"name"`
	Position
	Age   int  `json:"age"`
	Stale bool `json:"stale,omitempty"`
}

// Positions lists the last position of each squad member who has sent one.
func (s *State) Positions(squadID string, staleAfter time.Duration) []Located {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []Located{}
	now := s.now()
	for _, m := range s.squadMembers(squadID) {
		f, ok := s.fixes[m.ID]
		if !ok {
			continue
		}
		age := now.Sub(f.at)
		out = append(out, Located{MemberID: m.ID, Name: m.Name, Position: f.Position,
			Age: int(age / time.Second), Stale: age > staleAfter})
	}
	return out
}

func (s *State) Counts() (squads, members int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.squads), len(s.members)
}
