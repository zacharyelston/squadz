'use client';

import { useState } from 'react';
import { createSquad, getSquad } from '@/lib/api';
import { Squad } from '@/types';

interface Props {
  onCreated: (squad: Squad, memberId: string) => void;
  onBack: () => void;
}

export default function CreateSquad({ onCreated, onBack }: Props) {
  const [squadName, setSquadName] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      const result = await createSquad(squadName, displayName);
      const squad = await getSquad(result.squad_id);
      onCreated(squad, result.member_id);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to create squad');
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

        <h1 className="text-3xl font-bold mb-8">Create a Squad</h1>

        <form onSubmit={handleSubmit} className="space-y-6">
          <div>
            <label className="block text-sm font-medium mb-2">Squad Name</label>
            <input
              type="text"
              value={squadName}
              onChange={(e) => setSquadName(e.target.value)}
              placeholder="My Awesome Squad"
              className="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg focus:outline-none focus:border-blue-500"
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
              className="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg focus:outline-none focus:border-blue-500"
              required
            />
          </div>

          {error && (
            <div className="text-red-400 text-sm">{error}</div>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-600 rounded-lg font-semibold transition-colors"
          >
            {loading ? 'Creating...' : 'Create Squad'}
          </button>
        </form>
      </div>
    </main>
  );
}
