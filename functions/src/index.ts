import { initializeApp } from "firebase-admin/app";
import {
  DocumentReference,
  Timestamp,
  getFirestore,
} from "firebase-admin/firestore";
import { MulticastMessage, getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";
import { onDocumentUpdatedWithAuthContext } from "firebase-functions/v2/firestore";
import { setGlobalOptions } from "firebase-functions/v2/options";

initializeApp();

setGlobalOptions({
  region: "us-central1",
  memory: "256MiB",
  maxInstances: 10,
});

const database = getFirestore();
const MAX_TOKENS_PER_BATCH = 500;

type SpotStatus =
  | "posted"
  | "claimed"
  | "arriving"
  | "completed"
  | "expired"
  | "cancelled";

interface SpotDocument {
  createdBy: string;
  claimedBy?: string;
  latitude: number;
  longitude: number;
  createdAt: Timestamp;
  leavingAt: Timestamp;
  cleanupAt?: Timestamp;
  status: SpotStatus;
}

interface DeviceDocument {
  installationID: string;
  platform: string;
  bundleID: string;
  fcmToken: string;
  apnsToken: string;
  authorizationStatus: string;
  notificationsAuthorized: boolean;
  createdAt: Timestamp;
  updatedAt: Timestamp;
}

interface NotificationPlan {
  eventType: string;
  recipientUserId: string;
  title: string;
  body: string;
  data: Record<string, string>;
}

interface TokenTarget {
  token: string;
  reference: DocumentReference;
}

export const notifySpotLifecycle = onDocumentUpdatedWithAuthContext(
  "spots/{spotId}",
  async (event) => {
    if (!event.data) {
      logger.info("Spot lifecycle event arrived without document data.", {
        spotId: event.params.spotId,
      });
      return;
    }

    const before = parseSpot(event.data.before.data());
    const after = parseSpot(event.data.after.data());

    if (!before || !after) {
      logger.warn("Spot lifecycle notification skipped because the document shape was invalid.", {
        spotId: event.params.spotId,
      });
      return;
    }

    const plans = buildNotificationPlans({
      spotId: event.params.spotId,
      before,
      after,
      actorUserId: event.authId,
    });

    if (plans.length === 0) {
      return;
    }

    for (const plan of plans) {
      await sendNotificationPlan(plan);
    }
  }
);

function parseSpot(data: Record<string, unknown> | undefined): SpotDocument | null {
  if (!data) {
    return null;
  }

  const {
    createdBy,
    claimedBy,
    latitude,
    longitude,
    createdAt,
    leavingAt,
    cleanupAt,
    status,
  } = data;

  const validStatuses: SpotStatus[] = [
    "posted",
    "claimed",
    "arriving",
    "completed",
    "expired",
    "cancelled",
  ];

  if (
    typeof createdBy !== "string" ||
    (claimedBy !== undefined && typeof claimedBy !== "string") ||
    typeof latitude !== "number" ||
    typeof longitude !== "number" ||
    !(createdAt instanceof Timestamp) ||
    !(leavingAt instanceof Timestamp) ||
    (cleanupAt !== undefined && !(cleanupAt instanceof Timestamp)) ||
    typeof status !== "string" ||
    !validStatuses.includes(status as SpotStatus)
  ) {
    return null;
  }

  return {
    createdBy,
    claimedBy,
    latitude,
    longitude,
    createdAt,
    leavingAt,
    cleanupAt,
    status: status as SpotStatus,
  };
}

function buildNotificationPlans(input: {
  spotId: string;
  before: SpotDocument;
  after: SpotDocument;
  actorUserId?: string;
}): NotificationPlan[] {
  const { spotId, before, after, actorUserId } = input;
  const baseData = {
    spotId,
    status: after.status,
    actorUserId: actorUserId ?? "",
  };

  if (
    after.status === "claimed" &&
    before.status !== "claimed" &&
    after.claimedBy &&
    after.createdBy !== after.claimedBy
  ) {
    return [
      {
        eventType: "spot_claimed",
        recipientUserId: after.createdBy,
        title: "Your spot was claimed",
        body: "A nearby driver just claimed your handoff.",
        data: {
          ...baseData,
          eventType: "spot_claimed",
          recipientRole: "leaving",
        },
      },
    ];
  }

  if (
    after.status === "arriving" &&
    before.status !== "arriving" &&
    after.claimedBy
  ) {
    return [
      {
        eventType: "driver_arriving",
        recipientUserId: after.createdBy,
        title: "Driver is arriving",
        body: "The claimant marked that they are on the way to your spot.",
        data: {
          ...baseData,
          eventType: "driver_arriving",
          recipientRole: "leaving",
        },
      },
    ];
  }

  if (after.status === "cancelled" && before.status !== "cancelled") {
    const title = "Handoff cancelled";
    const body = actorUserId === after.createdBy
      ? "The leaving driver cancelled this handoff."
      : actorUserId === after.claimedBy
        ? "The arriving driver cancelled this handoff."
        : "This handoff was cancelled.";

    return participantRecipients(after, actorUserId).map((recipientUserId) => ({
      eventType: "handoff_cancelled",
      recipientUserId,
      title,
      body,
      data: {
        ...baseData,
        eventType: "handoff_cancelled",
      },
    }));
  }

  if (after.status === "completed" && before.status !== "completed") {
    const title = "Handoff completed";
    const body = actorUserId === after.createdBy
      ? "The leaving driver marked the handoff complete."
      : actorUserId === after.claimedBy
        ? "The arriving driver marked the handoff complete."
        : "This handoff was marked complete.";

    return participantRecipients(after, actorUserId).map((recipientUserId) => ({
      eventType: "handoff_completed",
      recipientUserId,
      title,
      body,
      data: {
        ...baseData,
        eventType: "handoff_completed",
      },
    }));
  }

  return [];
}

function participantRecipients(spot: SpotDocument, actorUserId?: string): string[] {
  const recipients = new Set<string>();

  if (spot.createdBy) {
    recipients.add(spot.createdBy);
  }

  if (spot.claimedBy) {
    recipients.add(spot.claimedBy);
  }

  if (actorUserId) {
    recipients.delete(actorUserId);
  }

  return Array.from(recipients);
}

async function sendNotificationPlan(plan: NotificationPlan): Promise<void> {
  const tokenTargets = await loadRecipientTokens(plan.recipientUserId);

  if (tokenTargets.length === 0) {
    logger.info("No active device tokens found for SpotRelay notification recipient.", {
      eventType: plan.eventType,
      recipientUserId: plan.recipientUserId,
    });
    return;
  }

  const invalidTokenRefs: DocumentReference[] = [];

  for (const batch of chunk(tokenTargets, MAX_TOKENS_PER_BATCH)) {
    const message: MulticastMessage = {
      tokens: batch.map((target) => target.token),
      notification: {
        title: plan.title,
        body: plan.body,
      },
      data: plan.data,
      apns: {
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    };

    const response = await getMessaging().sendEachForMulticast(message);

    response.responses.forEach((result, index) => {
      if (result.success) {
        return;
      }

      const errorCode = result.error?.code ?? "unknown";

      logger.warn("SpotRelay push send failed for one device.", {
        eventType: plan.eventType,
        recipientUserId: plan.recipientUserId,
        errorCode,
      });

      if (isInvalidTokenError(errorCode)) {
        invalidTokenRefs.push(batch[index].reference);
      }
    });

    logger.info("SpotRelay push batch finished.", {
      eventType: plan.eventType,
      recipientUserId: plan.recipientUserId,
      attemptedCount: batch.length,
      successCount: response.successCount,
      failureCount: response.failureCount,
    });
  }

  if (invalidTokenRefs.length > 0) {
    const cleanupBatch = database.batch();
    invalidTokenRefs.forEach((reference) => cleanupBatch.delete(reference));
    await cleanupBatch.commit();

    logger.info("Removed invalid SpotRelay device tokens after push send.", {
      recipientUserId: plan.recipientUserId,
      removedCount: invalidTokenRefs.length,
    });
  }
}

async function loadRecipientTokens(userId: string): Promise<TokenTarget[]> {
  const snapshot = await database
    .collection("users")
    .doc(userId)
    .collection("devices")
    .where("notificationsAuthorized", "==", true)
    .get();

  const targets = snapshot.docs.flatMap((document) => {
    const device = parseDevice(document.data());

    if (!device || device.fcmToken.trim().length === 0) {
      return [];
    }

    return [
      {
        token: device.fcmToken,
        reference: document.ref,
      },
    ];
  });

  const uniqueTargets = new Map<string, TokenTarget>();
  targets.forEach((target) => {
    if (!uniqueTargets.has(target.token)) {
      uniqueTargets.set(target.token, target);
    }
  });

  return Array.from(uniqueTargets.values());
}

function parseDevice(data: Record<string, unknown> | undefined): DeviceDocument | null {
  if (!data) {
    return null;
  }

  const {
    installationID,
    platform,
    bundleID,
    fcmToken,
    apnsToken,
    authorizationStatus,
    notificationsAuthorized,
    createdAt,
    updatedAt,
  } = data;

  if (
    typeof installationID !== "string" ||
    typeof platform !== "string" ||
    typeof bundleID !== "string" ||
    typeof fcmToken !== "string" ||
    typeof apnsToken !== "string" ||
    typeof authorizationStatus !== "string" ||
    typeof notificationsAuthorized !== "boolean" ||
    !(createdAt instanceof Timestamp) ||
    !(updatedAt instanceof Timestamp)
  ) {
    return null;
  }

  return {
    installationID,
    platform,
    bundleID,
    fcmToken,
    apnsToken,
    authorizationStatus,
    notificationsAuthorized,
    createdAt,
    updatedAt,
  };
}

function isInvalidTokenError(errorCode: string): boolean {
  return (
    errorCode === "messaging/invalid-registration-token" ||
    errorCode === "messaging/registration-token-not-registered"
  );
}

function chunk<T>(items: T[], size: number): T[][] {
  if (size <= 0) {
    return [items];
  }

  const batches: T[][] = [];
  for (let index = 0; index < items.length; index += size) {
    batches.push(items.slice(index, index + size));
  }
  return batches;
}
