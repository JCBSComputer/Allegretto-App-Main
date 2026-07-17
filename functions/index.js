const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const { GoogleAuth } = require("google-auth-library");

admin.initializeApp();

/**
 * Sends notifications to Developers when a file is uploaded.
 * Uses high-priority delivery and direct tokens to bypass background blocks.
 */
exports.sendDeveloperNotification = onDocumentCreated({
    document: "notifications/{notificationId}",
    region: "us-central1"
}, async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;
    const data = snapshot.data();

    const title = data.title || "Allegretto Vault Alert";
    const body = data.body || "New upload pending in the developer tab.";
    const targetToken = data.targetToken || null;

    const payload = {
        notification: { title, body },
        data: {
            click_action: "FLUTTER_NOTIFICATION_CLICK",
            channelId: "developer_alerts_v3",
            type: "developer_upload",
            messageId: event.id,
            click_intent: "za.co.allegretto.eisteddfod.NOTIFY"
        },
        android: {
            priority: "high",
            ttl: 0, // Deliver immediately
            notification: {
                channelId: "developer_alerts_v3",
                priority: "max",
                icon: "ic_launcher",
                visibility: "public",
                directBootOk: true,
                clickAction: "FLUTTER_NOTIFICATION_CLICK"
            },
        },
        webpush: {
            headers: { Urgency: "high" },
            notification: {
                title, body,
                icon: "https://allegretto-eisteddfod.co.za/favicon.png",
                requireInteraction: true
            }
        }
    };

    try {
        const dispatches = [];

        // 1. Send to standard Topic
        dispatches.push(admin.messaging().send({ ...payload, topic: "developers" }));

        // 2. If it's a test from the Repair tool, target that specific device token
        if (targetToken) {
            dispatches.push(admin.messaging().send({ ...payload, token: targetToken }));
        }

        // 3. Fallback: Target all dev tokens recorded in Firestore (Bypasses Topic blocks)
        const devUsers = await admin.firestore().collection('users')
            .where('is_developer', 'in', [true, 'true'])
            .get();

        devUsers.forEach(doc => {
            const token = doc.data().fcmToken;
            // Only add if not already the targetToken to avoid double send
            if (token && token !== targetToken) {
                dispatches.push(admin.messaging().send({ ...payload, token: token }));
            }
        });

        const results = await Promise.allSettled(dispatches);
        console.log(`Developer alert cycle: ${results.filter(r => r.status === 'fulfilled').length} sent, ${results.filter(r => r.status === 'rejected').length} failed.`);

        return snapshot.ref.delete();
    } catch (error) {
        console.error("Critical FCM Error:", error);
        return null;
    }
});

/**
 * Automatically sends notifications to developers when files are added to dev_files collection.
 * This ensures all developer file uploads trigger notifications, regardless of upload method.
 */
exports.notifyDeveloperFileUpload = onDocumentCreated({
    document: "dev_files/{fileId}",
    region: "us-central1"
}, async (event) => {
    const snapshot = event.data;
    if (!snapshot) return null;
    const data = snapshot.data();

    // Only notify for actual files, not folders
    if (data.isFolder) return null;

    const title = "New Developer File Uploaded";
    const body = `${data.uploader || 'Someone'} uploaded "${data.name}" to the developer vault.`;

    try {
        const dispatches = [];

        // 1. Send to standard Topic
        const topicPayload = {
            notification: { title, body },
            data: {
                click_action: "FLUTTER_NOTIFICATION_CLICK",
                channelId: "developer_alerts_v3",
                type: "developer_upload",
                fileId: event.id,
                fileName: data.name
            },
            android: {
                priority: "high",
                ttl: 0,
                notification: {
                    channelId: "developer_alerts_v3",
                    priority: "max",
                    icon: "ic_launcher",
                    visibility: "public",
                    clickAction: "FLUTTER_NOTIFICATION_CLICK"
                }
            },
            webpush: {
                headers: { Urgency: "high" },
                notification: {
                    title, body,
                    icon: "https://allegretto-eisteddfod.co.za/favicon.png",
                    requireInteraction: true
                }
            }
        };
        dispatches.push(admin.messaging().send({ ...topicPayload, topic: "developers" }));

        // 2. Fallback: Target all dev tokens recorded in Firestore
        const devUsers = await admin.firestore().collection('users')
            .where('is_developer', 'in', [true, 'true'])
            .get();

        devUsers.forEach(doc => {
            const token = doc.data().fcmToken;
            if (token) {
                dispatches.push(admin.messaging().send({ ...topicPayload, token: token }));
            }
        });

        const results = await Promise.allSettled(dispatches);
        console.log(`Developer file upload notification: ${results.filter(r => r.status === 'fulfilled').length} sent, ${results.filter(r => r.status === 'rejected').length} failed for: ${data.name}`);
    } catch (error) {
        console.error("Developer file upload notification error:", error);
    }

    return null;
});

/**
 * Ultimate Region Alert (Bell Icon Users)
 * Sends only to users who have specifically subscribed to the updated region.
 */
exports.notifyRegionUpdate = onDocumentUpdated({
    document: "region_config/{regionName}",
    region: "us-central1"
}, async (event) => {
    const beforeData = event.data.before.data() || {};
    const afterData = event.data.after.data() || {};
    const regionName = event.params.regionName;

    const beforeKeys = Object.keys(beforeData);
    const afterKeys = Object.keys(afterData);

    if (afterKeys.length > beforeKeys.length) {
        const newKey = afterKeys.find(key => !beforeKeys.includes(key));
        const title = `Region Update: ${regionName}`;
        const body = `New entry "${newKey}" was added to your region.`;

        const payload = {
            notification: { title, body },
            android: {
                priority: "high",
                ttl: 0,
                notification: {
                    channelId: "region_alerts_v3",
                    priority: "max",
                    icon: "ic_launcher",
                    directBootOk: true
                }
            },
            webpush: {
                notification: { title, body, icon: "https://allegretto-eisteddfod.co.za/favicon.png" }
            }
        };

        try {
            const dispatches = [];
            // Send to topic
            dispatches.push(admin.messaging().send({ ...payload, topic: `region_${regionName.replaceAll(' ', '_')}` }));

            // Direct fallback for users with this region in their list
            const subscribers = await admin.firestore().collection('users')
                .where('subscribed_regions', 'array-contains', regionName)
                .get();

            subscribers.forEach(doc => {
                if (doc.data().fcmToken) {
                    dispatches.push(admin.messaging().send({ ...payload, token: doc.data().fcmToken }));
                }
            });

            await Promise.allSettled(dispatches);
            console.log(`Region update successfully broadcasted for ${regionName}.`);
        } catch (e) { console.error("Region Notify Error:", e); }
    }
    return null;
});

// ── Purchase verification ──────────────────────────────────────────────────

const PACKAGE_NAME = "za.co.allegretto.eisteddfod";
const PRODUCT_MAP = { ads_removal_monthly: "is_subscribed", pro_offline_monthly: "is_pro" };

async function verifyGooglePlayPurchase(productId, purchaseToken) {
    const auth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/androidpublisher"] });
    const client = await auth.getClient();
    const url = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE_NAME}/purchases/subscriptions/${productId}/tokens/${purchaseToken}`;
    const response = await client.request({ url });
    const data = response.data;
    if (data.purchaseState !== 0) return null;
    return data.expiryTimeMillis ? Number(data.expiryTimeMillis) : null;
}

async function verifyAppleReceipt(receiptData) {
    const sharedSecret = process.env.APPSTORE_SHARED_SECRET;
    const response = await fetch("https://buy.itunes.apple.com/verifyReceipt", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ "receipt-data": receiptData, password: sharedSecret }),
    });
    const data = await response.json();
    if (data.status !== 0) return null;
    const latest = data.latest_receipt_info?.[0];
    return latest ? Number(latest.expires_date_ms) : null;
}

exports.verifyPurchase = onCall(async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "You must be logged in.");
    const { productId, purchaseToken, platform } = request.data;
    if (!productId || !purchaseToken || !platform) {
        throw new HttpsError("invalid-argument", "Missing productId, purchaseToken, or platform.");
    }
    const field = PRODUCT_MAP[productId];
    if (!field) throw new HttpsError("invalid-argument", `Unknown product: ${productId}`);

    let expiryTimeMillis = null;
    try {
        if (platform === "android") {
            expiryTimeMillis = await verifyGooglePlayPurchase(productId, purchaseToken);
        } else if (platform === "ios") {
            expiryTimeMillis = await verifyAppleReceipt(purchaseToken);
        } else {
            throw new HttpsError("invalid-argument", `Unsupported platform: ${platform}`);
        }
    } catch (err) {
        console.error(`Receipt verification failed for user ${uid}:`, err);
        throw new HttpsError("internal", `Verification failed: ${err.message}`);
    }

    if (expiryTimeMillis === null) throw new HttpsError("failed-precondition", "Purchase not valid or already consumed.");

    await admin.firestore().collection("users").doc(uid).update({
        [field]: true,
        subscriptionExpiryDate: admin.firestore.Timestamp.fromMillis(expiryTimeMillis),
        lastPaymentDate: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true, productId };
});
