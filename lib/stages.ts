// Shared with client components, so no server imports here.
export const LEAD_STAGES = ['Signal', 'Qualified', 'Contacted', 'Conversation', 'Proposal', 'Won', 'Lost', 'Watch'] as const;
export type LeadStage = (typeof LEAD_STAGES)[number];
