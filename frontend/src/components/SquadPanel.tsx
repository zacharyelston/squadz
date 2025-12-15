'use client';

import { useState } from 'react';
import { Squad, MemberLocation } from '@/types';
import { leaveSquad } from '@/lib/api';

interface Props {
  squad: Squad;
  memberId: string;
  locations: MemberLocation[];
  onLeave: () => void;
}

export default function SquadPanel({ squad, memberId, locations, onLeave }: Props) {
  const [showCode, setShowCode] = useState(false);
  const [leaving, setLeaving] = useState(false);

  const handleLeave = async () => {
    if (!confirm('Are you sure you want to leave this squad?')) return;
    
    setLeaving(true);
    try {
      await leaveSquad(squad.squad_id, memberId);
      onLeave();
    } catch (err) {
      console.error('Failed to leave squad:', err);
      setLeaving(false);
    }
  };

  const copyCode = () => {
    navigator.clipboard.writeText(squad.join_code);
  };

  const isLeader = squad.leader_id === memberId;

  return (
    <div className="p-4 flex flex-col h-full">
      {/* Header */}
      <div className="mb-6">
        <h2 className="text-xl font-bold">{squad.name}</h2>
        <p className="text-gray-400 text-sm">
          {squad.members.length} member{squad.members.length !== 1 ? 's' : ''}
        </p>
      </div>

      {/* Join Code */}
      <div className="mb-6 p-3 bg-gray-700 rounded-lg">
        <div className="flex items-center justify-between mb-1">
          <span className="text-sm text-gray-400">Join Code</span>
          <button
            onClick={() => setShowCode(!showCode)}
            className="text-xs text-blue-400 hover:text-blue-300"
          >
            {showCode ? 'Hide' : 'Show'}
          </button>
        </div>
        <div className="flex items-center gap-2">
          <code className="text-lg font-mono tracking-widest">
            {showCode ? squad.join_code : '••••••'}
          </code>
          {showCode && (
            <button
              onClick={copyCode}
              className="text-xs text-gray-400 hover:text-white"
            >
              Copy
            </button>
          )}
        </div>
      </div>

      {/* Members List */}
      <div className="flex-1 overflow-y-auto">
        <h3 className="text-sm font-semibold text-gray-400 mb-2">Members</h3>
        <ul className="space-y-2">
          {squad.members.map((member) => {
            const location = locations.find((l) => l.member_id === member.member_id);
            const isMe = member.member_id === memberId;

            return (
              <li
                key={member.member_id}
                className={`p-2 rounded-lg ${isMe ? 'bg-blue-900/30' : 'bg-gray-700/50'}`}
              >
                <div className="flex items-center gap-2">
                  {/* Status dot */}
                  <div
                    className={`w-2 h-2 rounded-full ${
                      location
                        ? location.is_stale
                          ? 'bg-gray-500'
                          : 'bg-green-500'
                        : 'bg-gray-600'
                    }`}
                  />
                  
                  <span className="font-medium">
                    {member.display_name}
                    {isMe && <span className="text-blue-400 text-xs ml-1">(You)</span>}
                    {member.is_leader && <span className="text-yellow-400 text-xs ml-1">★</span>}
                  </span>
                </div>
                
                {location && (
                  <div className="text-xs text-gray-400 mt-1 ml-4">
                    {location.is_stale ? 'Last seen ' : ''}
                    {new Date(location.updated_at).toLocaleTimeString()}
                    {location.location.speed !== undefined && location.location.speed > 0 && (
                      <span className="ml-2">
                        {(location.location.speed * 3.6).toFixed(1)} km/h
                      </span>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      </div>

      {/* Actions */}
      <div className="mt-4 pt-4 border-t border-gray-700">
        <button
          onClick={handleLeave}
          disabled={leaving}
          className="w-full py-2 bg-red-600/20 hover:bg-red-600/30 text-red-400 rounded-lg text-sm transition-colors disabled:opacity-50"
        >
          {leaving ? 'Leaving...' : isLeader ? 'Delete Squad' : 'Leave Squad'}
        </button>
      </div>
    </div>
  );
}
