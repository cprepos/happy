-- Self-hosted voice: conversations are LiveKit rooms, not ElevenLabs conversations.
-- AlterTable
ALTER TABLE "VoiceConversation" ALTER COLUMN "elevenLabsConversationId" DROP NOT NULL,
ADD COLUMN     "language" TEXT,
ADD COLUMN     "roomName" TEXT,
ADD COLUMN     "sessionId" TEXT;

-- CreateIndex
CREATE UNIQUE INDEX "VoiceConversation_roomName_key" ON "VoiceConversation"("roomName");
