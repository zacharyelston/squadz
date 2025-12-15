'use client';

import { useState } from 'react';
import { findSquadByCode, joinSquad } from '@/lib/api';
import { Squad } from '@/types';

interface Props {
  onJoined: (squad: Squad, memberId: string) => void;
  onBack: () => void;
}

export default function JoinSquad({ onJoined, onBack }: Props) {
  const [joinCode, setJoinCode] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      // Find squad by code
      const squad = await findSquadByCode(joinCode.toUpperCase());
      if (!squad) {
        throw new Error('Invalid join code');
      }

      // Join the squad
      const result = await joinSquad(squad.squad_id, joinCode.toUpperCase(), displayName);
      onJoined(result.squad, result.member_id);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to join squad');
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="min-h-screen flex flex-col items-center justify-center p-8">
      <div className="w-full max-w-md">
        <button
          onClick={onBack}
          className="mb-6 text-gray-400 hover:text-white flex items-center gap-2"
        >
          ← Back
        </button>

        <h1 className="text-3xl font-bold mb-8">Join a Squad</h1>

        <form onSubmit={handleSubmit} className="space-y-6">
          <div>
            <label className="block text-sm font-medium mb-2">Join Code</label>
            <input
              type="text"
              value={joinCode}
              onChange={(e) => setJoinCode(e.target.value.toUpperCase())}
              placeholder="ABC123"
              maxLength={6}
              className="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg focus:outline-none focus:border-green-500 text-center text-2xl tracking-widest font-mono"
              required
            />
          </div>

          <div>
            <label className="block text-sm font-medium mb-2">Your Display Name</label>
            <input
              type="text"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="Your name"
              className="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg focus:outline-none focus:border-green-500"
              required
            />
          </div>

          {error && (
            <div className="text-red-400 text-sm">{error}</div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full py-3 bg-green-600 hover:bg-green-700 disabled:bg-gray-600 rounded-lg font-semibold transition-colors"
          >
            {loading ? 'Joining...' : 'Join Squad'}
          </button>
        </form>
      </div>
    </main>
  );
}
