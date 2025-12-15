//! Squad management service

use std::collections::HashMap;
use chrono::Utc;
use rand::Rng;
use uuid::Uuid;

use crate::models::{Member, Squad, SquadSettings};

/// Manages squads and membership
pub struct SquadManager {
    squads: HashMap<Uuid, Squad>,
    join_codes: HashMap<String, Uuid>,
}

impl SquadManager {
    pub fn new() -> Self {
        Self {
            squads: HashMap::new(),
            join_codes: HashMap::new(),
        }
    }

    /// Generate a unique 6-character join code
    fn generate_join_code(&self) -> String {
        let chars: Vec<char> = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".chars().collect();
        loop {
            let code: String = (0..6)
                .map(|_| chars[rand::thread_rng().gen_range(0..chars.len())])
                .collect();
            if !self.join_codes.contains_key(&code) {
                return code;
            }
        }
    }

    /// Create a new squad
    pub fn create_squad(
        &mut self,
        name: String,
        leader_name: String,
        settings: Option<SquadSettings>,
    ) -> (Squad, Uuid) {
        let squad_id = Uuid::new_v4();
        let leader_id = Uuid::new_v4();
        let join_code = self.generate_join_code();

        let leader = Member {
            member_id: leader_id,
            display_name: leader_name,
            avatar_url: None,
            joined_at: Utc::now(),
            is_leader: true,
        };

        let squad = Squad {
            squad_id,
            name,
            join_code: join_code.clone(),
            created_at: Utc::now(),
            leader_id,
            members: vec![leader],
            settings: settings.unwrap_or_default(),
        };

        self.join_codes.insert(join_code, squad_id);
        self.squads.insert(squad_id, squad.clone());

        (squad, leader_id)
    }

    /// Get a squad by ID
    pub fn get_squad(&self, squad_id: &Uuid) -> Option<&Squad> {
        self.squads.get(squad_id)
    }

    /// Get a squad by join code
    pub fn get_squad_by_code(&self, join_code: &str) -> Option<&Squad> {
        self.join_codes
            .get(join_code)
            .and_then(|id| self.squads.get(id))
    }

    /// List all squads (for admin/debug)
    pub fn list_squads(&self) -> Vec<&Squad> {
        self.squads.values().collect()
    }

    /// Join a squad
    pub fn join_squad(
        &mut self,
        join_code: &str,
        display_name: String,
    ) -> Result<(Squad, Uuid), SquadError> {
        let squad_id = self
            .join_codes
            .get(join_code)
            .copied()
            .ok_or(SquadError::InvalidJoinCode)?;

        let squad = self
            .squads
            .get_mut(&squad_id)
            .ok_or(SquadError::SquadNotFound)?;

        // Check if name is taken
        if squad.members.iter().any(|m| m.display_name == display_name) {
            return Err(SquadError::NameTaken);
        }

        let member_id = Uuid::new_v4();
        let member = Member {
            member_id,
            display_name,
            avatar_url: None,
            joined_at: Utc::now(),
            is_leader: false,
        };

        squad.members.push(member);

        Ok((squad.clone(), member_id))
    }

    /// Leave a squad
    pub fn leave_squad(
        &mut self,
        squad_id: &Uuid,
        member_id: &Uuid,
    ) -> Result<(), SquadError> {
        let squad = self
            .squads
            .get_mut(squad_id)
            .ok_or(SquadError::SquadNotFound)?;

        let idx = squad
            .members
            .iter()
            .position(|m| &m.member_id == member_id)
            .ok_or(SquadError::MemberNotFound)?;

        let member = &squad.members[idx];

        // If leader leaves, delete the squad
        if member.is_leader {
            self.join_codes.remove(&squad.join_code);
            self.squads.remove(squad_id);
            return Ok(());
        }

        squad.members.remove(idx);
        Ok(())
    }

    /// Delete a squad (leader only)
    pub fn delete_squad(
        &mut self,
        squad_id: &Uuid,
        member_id: &Uuid,
    ) -> Result<(), SquadError> {
        let squad = self
            .squads
            .get(squad_id)
            .ok_or(SquadError::SquadNotFound)?;

        if &squad.leader_id != member_id {
            return Err(SquadError::NotLeader);
        }

        self.join_codes.remove(&squad.join_code);
        self.squads.remove(squad_id);
        Ok(())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SquadError {
    #[error("Squad not found")]
    SquadNotFound,
    #[error("Invalid join code")]
    InvalidJoinCode,
    #[error("Member not found")]
    MemberNotFound,
    #[error("Display name already taken")]
    NameTaken,
    #[error("Only the leader can perform this action")]
    NotLeader,
}
