// API client for Squadz backend

import {
  Squad,
  CreateSquadResponse,
  JoinSquadResponse,
  SquadLocationsResponse,
  GeoPoint,
} from '@/types';

// Use relative URL to go through Next.js API proxy
const API_URL = '';

// The member's session key, returned by creating or joining a squad. It is
// held in memory only, like the rest of this page's squad state.
let apiKey: string | null = null;

async function fetchApi<T>(
  endpoint: string,
  options?: RequestInit
): Promise<T> {
  const url = `${API_URL}${endpoint}`;
  console.log(`[API] ${options?.method || 'GET'} ${url}`);
  
  try {
    const res = await fetch(url, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
        ...options?.headers,
      },
    });

    console.log(`[API] Response: ${res.status}`);

    if (!res.ok) {
      const error = await res.text();
      console.error(`[API] Error: ${error}`);
      throw new Error(error || `HTTP ${res.status}`);
    }

    // Some endpoints (e.g. POST /locations) reply 200 with an empty body
    const text = await res.text();
    return (text ? JSON.parse(text) : undefined) as T;
  } catch (err) {
    console.error(`[API] Fetch error:`, err);
    throw err;
  }
}

// Squad operations
export async function createSquad(
  name: string,
  leaderName: string
): Promise<CreateSquadResponse> {
  const result = await fetchApi<CreateSquadResponse>('/api/v1/squads', {
    method: 'POST',
    body: JSON.stringify({
      name,
      leader_name: leaderName,
    }),
  });
  apiKey = result.api_key;
  return result;
}

// The server never returns a join code here: only creating or joining does.
export async function getSquad(squadId: string): Promise<Omit<Squad, 'join_code'>> {
  return fetchApi(`/api/v1/squads/${squadId}`);
}

export async function joinSquad(
  joinCode: string,
  displayName: string
): Promise<JoinSquadResponse> {
  const result = await fetchApi<JoinSquadResponse>('/api/v1/join', {
    method: 'POST',
    body: JSON.stringify({
      join_code: joinCode,
      display_name: displayName,
    }),
  });
  apiKey = result.api_key;
  return result;
}

export async function leaveSquad(
  squadId: string,
  memberId: string
): Promise<void> {
  await fetchApi(`/api/v1/squads/${squadId}/leave`, {
    method: 'POST',
    body: JSON.stringify({ member_id: memberId }),
  });
  apiKey = null;
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
