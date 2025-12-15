'use client';

import { useState } from 'react';
import dynamic from 'next/dynamic';
import CreateSquad from '@/components/CreateSquad';
import JoinSquad from '@/components/JoinSquad';
import SquadPanel from '@/components/SquadPanel';
import { Squad, MemberLocation } from '@/types';

// Dynamic import for Leaflet (no SSR)
const SquadMap = dynamic(() => import('@/components/SquadMap'), {
  ssr: false,
  loading: () => (
    <div className="w-full h-full flex items-center justify-center bg-gray-800">
      <div className="text-gray-400">Loading map...</div>
    </div>
  ),
});

export default function Home() {
  const [squad, setSquad] = useState<Squad | null>(null);
  const [memberId, setMemberId] = useState<string | null>(null);
  const [locations, setLocations] = useState<MemberLocation[]>([]);
  const [view, setView] = useState<'home' | 'create' | 'join'>('home');

  const handleSquadCreated = (newSquad: Squad, newMemberId: string) => {
    setSquad(newSquad);
    setMemberId(newMemberId);
    setView('home');
  };

  const handleSquadJoined = (joinedSquad: Squad, newMemberId: string) => {
    setSquad(joinedSquad);
    setMemberId(newMemberId);
    setView('home');
  };

  const handleLeaveSquad = () => {
    setSquad(null);
    setMemberId(null);
    setLocations([]);
  };

  // Home screen - no squad yet
  if (!squad) {
    if (view === 'create') {
      return <CreateSquad onCreated={handleSquadCreated} onBack={() => setView('home')} />;
    }
    if (view === 'join') {
      return <JoinSquad onJoined={handleSquadJoined} onBack={() => setView('home')} />;
    }

    return (
      <main className="min-h-screen flex flex-col items-center justify-center p-8">
        <div className="text-center mb-12">
          <h1 className="text-5xl font-bold mb-4 bg-gradient-to-r from-blue-400 to-green-400 bg-clip-text text-transparent">
            Squadz
          </h1>
          <p className="text-gray-400 text-lg">
            Share your location with your squad in real-time
          </p>
        </div>

        <div className="flex flex-col sm:flex-row gap-4">
          <button
            onClick={() => setView('create')}
            className="px-8 py-4 bg-blue-600 hover:bg-blue-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Create Squad
          </button>
          <button
            onClick={() => setView('join')}
            className="px-8 py-4 bg-green-600 hover:bg-green-700 rounded-lg font-semibold text-lg transition-colors"
          >
            Join Squad
          </button>
        </div>
      </main>
    );
  }

  // Squad view with map
  return (
    <main className="h-screen flex flex-col md:flex-row">
      {/* Map */}
      <div className="flex-1 h-[60vh] md:h-full">
        <SquadMap
          squad={squad}
          memberId={memberId!}
          locations={locations}
          onLocationsUpdate={setLocations}
        />
      </div>

      {/* Side panel */}
      <div className="w-full md:w-80 h-[40vh] md:h-full bg-gray-800 border-t md:border-t-0 md:border-l border-gray-700 overflow-y-auto">
        <SquadPanel
          squad={squad}
          memberId={memberId!}
          locations={locations}
          onLeave={handleLeaveSquad}
        />
      </div>
    </main>
  );
}
