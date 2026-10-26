/**
 * Opt-in self-hosted build mode (SELFHOST=1).
 *
 * Produces an app that can be signed with a personal (free) Apple team and
 * talks to a self-hosted server:
 * - bundle id / Android package derived from APP_BUNDLE_ID_PREFIX
 * - display name from APP_DISPLAY_NAME (default "Happy")
 * - no EAS updates / projectId / owner (so no push token registration)
 * - no aps-environment entitlement and no remote-notification background mode
 *   (personal teams cannot sign the Push Notifications capability)
 * - no associated domains, Apple Pay or In-App Purchase related entitlements
 * - SELFHOST_SERVER_URL baked into extra.app.serverUrl and used as the default
 *   for EXPO_PUBLIC_HAPPY_SERVER_URL / EXPO_PUBLIC_SERVER_URL
 *
 * When SELFHOST is unset this module is never applied and the upstream
 * configuration is unchanged.
 */
const { withEntitlementsPlist, withInfoPlist } = require('@expo/config-plugins');

const BUNDLE_SUFFIX = {
    development: '.dev',
    preview: '.preview',
    production: '',
};

// Entitlements a personal Apple team cannot provision.
const BLOCKED_ENTITLEMENTS = [
    'aps-environment',
    'com.apple.developer.associated-domains',
    'com.apple.developer.in-app-payments',
    'com.apple.developer.applesignin',
    'com.apple.developer.icloud-container-identifiers',
    'com.apple.developer.icloud-services',
    'com.apple.developer.ubiquity-kvstore-identifier',
];

function isSelfHost(env = process.env) {
    return env.SELFHOST === '1' || env.SELFHOST === 'true';
}

function stripEntitlements(entitlements) {
    for (const key of BLOCKED_ENTITLEMENTS) {
        delete entitlements[key];
    }
    return entitlements;
}

function stripRemoteNotificationMode(infoPlist) {
    if (Array.isArray(infoPlist.UIBackgroundModes)) {
        infoPlist.UIBackgroundModes = infoPlist.UIBackgroundModes.filter((m) => m !== 'remote-notification');
        if (infoPlist.UIBackgroundModes.length === 0) {
            delete infoPlist.UIBackgroundModes;
        }
    }
    return infoPlist;
}

/**
 * Config plugin removing entitlements/background modes that other plugins
 * (notably expo-notifications, which always writes aps-environment) add.
 * Mods registered earlier run later, so this plugin must be the FIRST entry
 * in `plugins` to see the final entitlements.
 */
function withSelfHostIos(config) {
    config = withEntitlementsPlist(config, (cfg) => {
        stripEntitlements(cfg.modResults);
        return cfg;
    });
    config = withInfoPlist(config, (cfg) => {
        stripRemoteNotificationMode(cfg.modResults);
        return cfg;
    });
    return config;
}

/**
 * Rewrites the static app config for SELFHOST=1. Mutates and returns `config`
 * (the object exported by app.config.js, i.e. `{ expo: {...} }`).
 */
function applySelfHostConfig(config, variant, env = process.env) {
    const expo = config.expo;

    const prefix = env.APP_BUNDLE_ID_PREFIX;
    if (!prefix || !/^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$/.test(prefix)) {
        throw new Error(
            'SELFHOST=1 requires APP_BUNDLE_ID_PREFIX, a reverse-DNS id such as com.yourname.happy ' +
            '(letters and digits only, no hyphens), got: ' + JSON.stringify(prefix)
        );
    }
    const bundleId = prefix + (BUNDLE_SUFFIX[variant] ?? `.${variant}`);

    expo.name = env.APP_DISPLAY_NAME || 'Happy';
    expo.ios.bundleIdentifier = bundleId;
    expo.android.package = bundleId;

    // No universal links / Android app links to app.happy.engineering.
    delete expo.ios.associatedDomains;
    expo.android.intentFilters = [];

    // No push: drop the background remote-notification mode at the source,
    // the plugin below removes aps-environment and anything left over.
    expo.plugins = expo.plugins.map((plugin) => {
        if (Array.isArray(plugin) && plugin[0] === 'expo-notifications') {
            const { enableBackgroundRemoteNotifications, ...rest } = plugin[1] || {};
            return ['expo-notifications', { ...rest, enableBackgroundRemoteNotifications: false }];
        }
        return plugin;
    });
    expo.plugins.unshift(withSelfHostIos);

    // Detach from the upstream EAS project.
    expo.updates = { enabled: false };
    if (expo.extra) {
        delete expo.extra.eas;
    }
    delete expo.owner;

    const serverUrl = env.SELFHOST_SERVER_URL;
    if (serverUrl) {
        expo.extra = expo.extra || {};
        expo.extra.app = { ...(expo.extra.app || {}), serverUrl };
        // Best effort: EXPO_PUBLIC_* are inlined by babel at bundle time from
        // the bundler's environment. The build script should still export
        // these explicitly (or write them to .env.local).
        if (!env.EXPO_PUBLIC_HAPPY_SERVER_URL) env.EXPO_PUBLIC_HAPPY_SERVER_URL = serverUrl;
        if (!env.EXPO_PUBLIC_SERVER_URL) env.EXPO_PUBLIC_SERVER_URL = serverUrl;
    }

    return config;
}

module.exports = {
    isSelfHost,
    applySelfHostConfig,
    withSelfHostIos,
    stripEntitlements,
    stripRemoteNotificationMode,
};
