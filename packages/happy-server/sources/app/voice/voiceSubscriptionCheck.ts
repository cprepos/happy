import { log } from "@/utils/log";

/**
 * Whether the account has an active RevenueCat entitlement. Without
 * `REVENUECAT_API_KEY`, or if the check fails, the answer is no.
 */
export async function voiceSubscriptionCheck(userId: string): Promise<boolean> {
    const revenueCatApiKey = process.env.REVENUECAT_API_KEY;
    if (!revenueCatApiKey) return false;

    try {
        const response = await fetch(
            `https://api.revenuecat.com/v2/projects/proj493735ad/customers/${userId}/active_entitlements`,
            {
                method: "GET",
                headers: {
                    "Authorization": `Bearer ${revenueCatApiKey}`,
                },
            }
        );
        if (!response.ok) {
            log({ module: 'voice' }, `RevenueCat check failed for ${userId}: ${response.status}`);
            return false;
        }
        const data = (await response.json()) as { items?: Array<{ entitlement_id: string }> };
        return (data.items?.length ?? 0) > 0;
    } catch {
        return false;
    }
}
