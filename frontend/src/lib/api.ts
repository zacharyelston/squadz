// API client for Squadz backend

import {
  Squad,
  CreateSquadResponse,
  JoinSquadResponse,
  SquadLocationsResponse,
  GeoPoint,
} from '@/types';

const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8080';

async function fetchApi<T>(
  endpoint: string,
  options?: RequestInit
): Promise<T> {
  const res = await fetch(`${API_URL}${endpoint}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (!res.ok) {
    const error = await res.text();
    throw new Error(error || `HTTP ${res.status}`);
  }

  return res.json();
}

// Squad operations
export async function createSquad(
  name: string,
  leaderName: string
): Promise<CreateSquadResponse> {
  return fetchApi('/api/v1/squads', {
    method: 'POST',
    body: JSON.stringify({
      name,
      leader_name: leaderName,
    }),
  });
}

export async function getSquad(squadId: string): Promise<Squad> {
  return fetchApi(`/api/v1/squads/${squadId}`);
}

export async function joinSquad(
  squadId: string,
  joinCode: string,
  displayName: string
): Promise<JoinSquadResponse> {
  return fetchApi(`/api/v1/squads/${squadId}/join`, {
    method: 'POST',
    body: JSON.stringify({
      join_code: joinCode,
      display_name: displayName,
    }),
  });
}

export async function leaveSquad(
  squadId: string,
  memberId: string
): Promise<void> {
  await fetchApi(`/api/v1/squads/${squadId}/leave`, {
    method: 'POST',
    body: JSON.stringify({ member_id: memberId }),
  });
}

// Location operations
export async function updateLocation(
  squadId: string,
  memberId: string,
  location: GeoPoint
): Promise<void> {
  await fetchApi('/api/v1/locations', {
    method: 'POST',
    body: JSON.stringify({
      squad_id: squadId,
      member_id: memberId,
      location,
    }),
  });
}

export async function getSquadLocations(
  squadId: string
): Promise<SquadLocationsResponse> {
  return fetchApi(`/api/v1/squads/${squadId}/locations`);
}

// Find squad by join code (searches all squads - in production would be a dedicated endpoint)
export async function findSquadByCode(joinCode: string): Promise<Squad | null> {
  const squads: Squad[] = await fetchApi('/api/v1/squads');
  return squads.find((s) => s.join_code === joinCode) || null;
}
