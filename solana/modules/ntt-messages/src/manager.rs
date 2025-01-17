use std::io;

#[cfg(feature = "anchor")]
use anchor_lang::prelude::*;

use wormhole_io::{Readable, TypePrefixedPayload, Writeable};

use crate::utils::maybe_space::MaybeSpace;

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(
    feature = "anchor",
    derive(AnchorSerialize, AnchorDeserialize, InitSpace)
)]
pub struct ManagerMessage<A: MaybeSpace> {
    pub sequence: u64,
    pub sender: [u8; 32],
    pub payload: A,
}

#[cfg(feature = "hash")]
impl<A: MaybeSpace> ManagerMessage<A>
where
    ManagerMessage<A>: TypePrefixedPayload,
{
    pub fn keccak256(&self, chain_id: crate::chain_id::ChainId) -> solana_program::keccak::Hash {
        let mut bytes: Vec<u8> = Vec::new();
        bytes.extend_from_slice(&chain_id.id.to_be_bytes());
        bytes.extend_from_slice(&TypePrefixedPayload::to_vec_payload(self));
        solana_program::keccak::hash(&bytes)
    }
}

impl<A: TypePrefixedPayload + MaybeSpace> TypePrefixedPayload for ManagerMessage<A> {
    const TYPE: Option<u8> = None;
}

impl<A: TypePrefixedPayload + MaybeSpace> Readable for ManagerMessage<A> {
    const SIZE: Option<usize> = None;

    fn read<R>(reader: &mut R) -> io::Result<Self>
    where
        Self: Sized,
        R: io::Read,
    {
        let sequence = Readable::read(reader)?;
        let sender = Readable::read(reader)?;
        // TODO: same as below for manager payload
        let _payload_len: u16 = Readable::read(reader)?;
        let payload = A::read_payload(reader)?;

        Ok(Self {
            sequence,
            sender,
            payload,
        })
    }
}

impl<A: TypePrefixedPayload + MaybeSpace> Writeable for ManagerMessage<A> {
    fn written_size(&self) -> usize {
        u64::SIZE.unwrap()
            + self.sender.len()
            + u16::SIZE.unwrap() // payload length
            + self.payload.written_size()
    }

    fn write<W>(&self, writer: &mut W) -> io::Result<()>
    where
        W: io::Write,
    {
        let ManagerMessage {
            sequence,
            sender,
            payload,
        } = self;

        sequence.write(writer)?;
        writer.write_all(sender)?;
        let len: u16 = u16::try_from(payload.written_size()).expect("u16 overflow");
        len.write(writer)?;
        // TODO: same as above
        A::write_payload(payload, writer)
    }
}
