'use client';

import { useEffect, useRef, useCallback } from 'react';
import { MapContainer, TileLayer, Marker, Popup, useMap } from 'react-leaflet';
import L from 'leaflet';
import { Squad, MemberLocation, GeoPoint } from '@/types';
import { updateLocation, getSquadLocations } from '@/lib/api';

interface Props {
  squad: Squad;
  memberId: string;
  locations: MemberLocation[];
  onLocationsUpdate: (locations: MemberLocation[]) => void;
}

// Custom marker icons
const createIcon = (color: string, isMe: boolean) => {
  return L.divIcon({
    className: 'custom-marker',
    html: `
      <div style="
        width: ${isMe ? '20px' : '16px'};
        height: ${isMe ? '20px' : '16px'};
        background: ${color};
        border: 2px solid white;
        border-radius: 50%;
        box-shadow: 0 2px 4px rgba(0,0,0,0.3);
      "></div>
    `,
    iconSize: [isMe ? 20 : 16, isMe ? 20 : 16],
    iconAnchor: [isMe ? 10 : 8, isMe ? 10 : 8],
  });
};

// Component to handle map centering
function MapController({ center }: { center: [number, number] | null }) {
  const map = useMap();
  
  useEffect(() => {
    if (center) {
      map.setView(center, map.getZoom());
    }
  }, [center, map]);
  
  return null;
}

export default function SquadMap({ squad, memberId, locations, onLocationsUpdate }: Props) {
  const watchIdRef = useRef<number | null>(null);
  const myLocationRef = useRef<GeoPoint | null>(null);

  // Start watching position
  const startWatching = useCallback(() => {
    if (!navigator.geolocation) {
      console.error('Geolocation not supported');
      return;
    }

    watchIdRef.current = navigator.geolocation.watchPosition(
      async (position) => {
        const location: GeoPoint = {
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
          altitude: position.coords.altitude ?? undefined,
          accuracy: position.coords.accuracy ?? undefined,
          heading: position.coords.heading ?? undefined,
          speed: position.coords.speed ?? undefined,
        };

        myLocationRef.current = location;

        // Send to server
        try {
          await updateLocation(squad.squad_id, memberId, location);
        } catch (err) {
          console.error('Failed to update location:', err);
        }
      },
      (error) => {
        console.error('Geolocation error:', error);
      },
      {
        enableHighAccuracy: true,
        timeout: 10000,
        maximumAge: 5000,
      }
    );
  }, [squad.squad_id, memberId]);

  // Poll for squad locations
  const pollLocations = useCallback(async () => {
    try {
      const response = await getSquadLocations(squad.squad_id);
      onLocationsUpdate(response.locations);
    } catch (err) {
      console.error('Failed to get locations:', err);
    }
  }, [squad.squad_id, onLocationsUpdate]);

  useEffect(() => {
    startWatching();
    pollLocations();

    // Poll every 5 seconds
    const interval = setInterval(pollLocations, 5000);

    return () => {
      if (watchIdRef.current !== null) {
        navigator.geolocation.clearWatch(watchIdRef.current);
      }
      clearInterval(interval);
    };
  }, [startWatching, pollLocations]);

  // Find my location for centering
  const myLocation = locations.find((l) => l.member_id === memberId);
  const center: [number, number] | null = myLocation
    ? [myLocation.location.latitude, myLocation.location.longitude]
    : null;

  // Default center (San Francisco) if no location yet
  const defaultCenter: [number, number] = [37.7749, -122.4194];

  return (
    <MapContainer
      center={center || defaultCenter}
      zoom={15}
      className="w-full h-full"
      zoomControl={true}
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      
      <MapController center={center} />

      {locations.map((loc) => {
        const isMe = loc.member_id === memberId;
        const color = isMe ? '#3b82f6' : loc.is_stale ? '#6b7280' : '#10b981';
        
        return (
          <Marker
            key={loc.member_id}
            position={[loc.location.latitude, loc.location.longitude]}
            icon={createIcon(color, isMe)}
          >
            <Popup>
              <div className="text-gray-900">
                <strong>{loc.display_name}</strong>
                {isMe && <span className="text-blue-600 ml-1">(You)</span>}
                {loc.is_stale && <span className="text-gray-500 ml-1">(Stale)</span>}
                <br />
                <span className="text-xs text-gray-600">
                  {new Date(loc.updated_at).toLocaleTimeString()}
                </span>
                {loc.location.speed !== undefined && loc.location.speed > 0 && (
                  <span className="text-xs text-gray-600 ml-2">
                    {(loc.location.speed * 3.6).toFixed(1)} km/h
                  </span>
                )}
              </div>
            </Popup>
          </Marker>
        );
      })}
    </MapContainer>
  );
}
