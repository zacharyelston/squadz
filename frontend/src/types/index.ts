// Types matching backend models

export interface GeoPoint {
  latitude: number;
  longitude: number;
  altitude?: number;
  accuracy?: number;
  heading?: number;
  speed?: number;
}

export interface Member {
  member_id: string;
  display_name: string;
  avatar_url?: string;
  joined_at: string;
  is_leader: boolean;
}

export interface SquadSettings {
  is_public: boolean;
  require_approval: boolean;
  share_altitude: boolean;
  share_speed: boolean;
  location_update_interval_secs: number;
}

export interface Squad {
  squad_id: string;
  name: string;
  join_code: string;
  created_at: string;
  leader_id: string;
  members: Member[];
  settings: SquadSettings;
}

export interface MemberLocation {
  member_id: string;
  display_name: string;
  location: GeoPoint;
  updated_at: string;
  is_stale: boolean;
}

export interface CreateSquadResponse {
  squad_id: string;
  join_code: string;
  member_id: string;
}

export interface JoinSquadResponse {
  member_id: string;
  squad: Squad;
}

export interface SquadLocationsResponse {
  squad_id: string;
  squad_name: string;
  locations: MemberLocation[];
  updated_at: string;
}
