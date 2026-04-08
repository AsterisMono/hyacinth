package io.hyacinth.hyacinth

import android.app.admin.DeviceAdminReceiver

/// M9 — Device Admin receiver.
///
/// We declare only the `force-lock` policy (see res/xml/device_admin.xml) so
/// the off path can call `DevicePolicyManager.lockNow()`. No keyguard
/// features, no password management — M7.5 territory.
class HyacinthDeviceAdminReceiver : DeviceAdminReceiver()
