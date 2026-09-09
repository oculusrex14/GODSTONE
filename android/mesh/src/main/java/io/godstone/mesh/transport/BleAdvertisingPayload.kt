package io.godstone.mesh.transport

import java.util.UUID
import java.util.LinkedHashMap

/**
 * T09: canonical BLE advertising payload for the mesh.
 *
 * The air payload of a GodStone peripheral is exactly one AD structure set:
 * the Flags AD and one Complete List of 128-bit Service Class UUIDs holding
 * the canonical service UUID. It carries no Service Data, no Manufacturer
 * Specific Data, no device name and no Tx Power, so the 13 octets of the
 * LinkInfo record never ride the legacy advertisement; they are served by
 * GATT (see the linkInfo characteristic provider on BleGattServer).
 *
 * This class is the inspectable AdvertiseData-equivalent that the canonical
 * adapter (BleAdvertiser) translates into platform builder instructions via
 * AdvertisingHooks. It is deliberately free of android.* imports so unit
 * tests on the JVM can inspect every instruction the platform receives.
 */
class BleAdvertisingPayload {

    /** Complete List of 128-bit Service Class UUIDs; canonical size 1. */
    val serviceUuids = mutableListOf<UUID>()

    /** Service Data (128-bit UUID keyed). Canonical content: empty. */
    private val serviceDataEntries = LinkedHashMap<UUID, ByteArray>()

    /** Manufacturer Specific Data (company-id keyed). Canonical content: empty. */
    private val manufacturerDataEntries = LinkedHashMap<Int, ByteArray>()

    /** The Flags AD is required: a connectable peripheral advertises LE general discoverability. */
    var includesFlags: Boolean = true

    /** Local name AD inclusion: forbidden in the canonical payload (identity hint leak). */
    var includesDeviceName: Boolean = false

    /** Tx Power AD inclusion: forbidden in the canonical payload (budget and privacy). */
    var includesTxPower: Boolean = false

    fun addServiceUuid(uuid: UUID): BleAdvertisingPayload {
        serviceUuids.add(uuid)
        return this
    }

    fun addServiceData(uuid: UUID, data: ByteArray): BleAdvertisingPayload {
        serviceDataEntries[uuid] = data.copyOf()
        return this
    }

    fun addManufacturerData(companyId: Int, data: ByteArray): BleAdvertisingPayload {
        manufacturerDataEntries[companyId] = data.copyOf()
        return this
    }

    /** Read-only image of the Service Data entries, defensive copies. */
    fun serviceData(): Map<UUID, ByteArray> {
        val image = LinkedHashMap<UUID, ByteArray>()
        for ((uuid, bytes) in serviceDataEntries) {
            image[uuid] = bytes.copyOf()
        }
        return image
    }

    /** Read-only image of the Manufacturer Specific Data entries, defensive copies. */
    fun manufacturerData(): Map<Int, ByteArray> {
        val image = LinkedHashMap<Int, ByteArray>()
        for ((companyId, bytes) in manufacturerDataEntries) {
            image[companyId] = bytes.copyOf()
        }
        return image
    }

    /**
     * The ordered instruction stream the canonical adapter will execute
     * against the platform AdvertiseData.Builder. One instruction per
     * builder call; the recording hooks in tests observe exactly this stream.
     */
    fun toInstructions(): List<AdvertiseInstruction> {
        val instructions = ArrayList<AdvertiseInstruction>()
        for (uuid in serviceUuids) {
            instructions.add(AdvertiseInstruction.AddServiceUuid(uuid))
        }
        for ((uuid, bytes) in serviceDataEntries) {
            instructions.add(AdvertiseInstruction.AddServiceData(uuid, bytes.copyOf()))
        }
        for ((companyId, bytes) in manufacturerDataEntries) {
            instructions.add(AdvertiseInstruction.AddManufacturerData(companyId, bytes.copyOf()))
        }
        instructions.add(AdvertiseInstruction.IncludeDeviceName(includesDeviceName))
        instructions.add(AdvertiseInstruction.IncludeTxPowerLevel(includesTxPower))
        return instructions
    }

    /**
     * Legacy advertising data accounting over the air: the sum of the AD
     * structure lengths this payload would occupy inside the 31-octet legacy
     * Advertising Data channel.
     *
     * Each AD structure costs one Length octet, one AD Type octet and its AD
     * Data. The estimates for variable AD Data follow the conservative
     * platform-legality principle: a device name is counted at its typical
     * length, because any longer name only makes the overflow larger.
     */
    fun legacyOnAirOctets(): Int {
        var octets = 0
        if (includesFlags) {
            octets += FLAGS_AD_OCTETS
        }
        if (serviceUuids.isNotEmpty()) {
            octets += SERVICE_UUID128_LIST_AD_OCTETS
        }
        for ((uuid, bytes) in serviceDataEntries) {
            octets += SERVICE_DATA_128_AD_BASE_OCTETS + bytes.size
        }
        for ((company, bytes) in manufacturerDataEntries) {
            octets += MANUFACTURER_DATA_AD_BASE_OCTETS + bytes.size
        }
        if (includesDeviceName) {
            octets += COMPLETE_LOCAL_NAME_AD_TYPICAL_OCTETS
        }
        if (includesTxPower) {
            octets += TX_POWER_AD_OCTETS
        }
        return octets
    }

    /**
     * Adapter assertion: the payload fits the legacy advertising budget.
     * An oversized payload would be rejected by the platform with
     * ADVERTISE_FAILED_DATA_TOO_LARGE; refusing it before dispatch keeps the
     * previous advertising state authoritative.
     */
    fun fitsLegacyBudget(): Boolean = legacyOnAirOctets() <= LEGACY_ADVERTISING_DATA_MAX_OCTETS

    companion object {

        /** Legacy Advertising Data channel budget (Core 5.3, non-extended). */
        const val LEGACY_ADVERTISING_DATA_MAX_OCTETS: Int = 31

        /** Flags AD structure: Length, Type, one Flags octet. */
        const val FLAGS_AD_OCTETS: Int = 3

        /** Complete List of one 128-bit Service Class UUID: Length, Type, 16 octets. */
        const val SERVICE_UUID128_LIST_AD_OCTETS: Int = 18

        /** Service Data AD with a 128-bit UUID, excluding the data octets. */
        const val SERVICE_DATA_128_AD_BASE_OCTETS: Int = 18

        /** Manufacturer Specific Data AD, excluding the company data octets. */
        const val MANUFACTURER_DATA_AD_BASE_OCTETS: Int = 4

        /** Complete Local Name AD counted at a typical name length (conservative). */
        const val COMPLETE_LOCAL_NAME_AD_TYPICAL_OCTETS: Int = 12

        /** Tx Power AD structure: Length, Type, one power octet. */
        const val TX_POWER_AD_OCTETS: Int = 3

        /**
         * The canonical mesh advertisement: exactly the Flags AD and the
         * complete 128-bit service UUID list for [serviceUuid]. Nothing else
         * ever rides the air.
         */
        fun canonical(serviceUuid: UUID): BleAdvertisingPayload {
            val payload = BleAdvertisingPayload()
            payload.addServiceUuid(serviceUuid)
            payload.includesFlags = true
            payload.includesDeviceName = false
            payload.includesTxPower = false
            return payload
        }
    }
}

/**
 * One executed instruction of the advertising adapter: the faithful image of
 * exactly one call the production hooks make on the platform
 * android.bluetooth.le.AdvertiseData.Builder.
 */
sealed class AdvertiseInstruction {

    class AddServiceUuid(val uuid: UUID) : AdvertiseInstruction() {
        override fun equals(other: Any?): Boolean =
            other is AddServiceUuid && other.uuid == uuid

        override fun hashCode(): Int = uuid.hashCode()

        override fun toString(): String = "AddServiceUuid($uuid)"
    }

    class AddServiceData(val uuid: UUID, val data: ByteArray) : AdvertiseInstruction() {
        override fun equals(other: Any?): Boolean =
            other is AddServiceData && other.uuid == uuid && other.data.contentEquals(data)

        override fun hashCode(): Int = 31 * uuid.hashCode() + data.contentHashCode()

        override fun toString(): String = "AddServiceData($uuid, ${data.size} octets)"
    }

    class AddManufacturerData(val companyId: Int, val data: ByteArray) : AdvertiseInstruction() {
        override fun equals(other: Any?): Boolean =
            other is AddManufacturerData && other.companyId == companyId && other.data.contentEquals(data)

        override fun hashCode(): Int = 31 * companyId + data.contentHashCode()

        override fun toString(): String = "AddManufacturerData($companyId, ${data.size} octets)"
    }

    class IncludeDeviceName(val include: Boolean) : AdvertiseInstruction() {
        override fun equals(other: Any?): Boolean =
            other is IncludeDeviceName && other.include == include

        override fun hashCode(): Int = include.hashCode()

        override fun toString(): String = "IncludeDeviceName($include)"
    }

    class IncludeTxPowerLevel(val include: Boolean) : AdvertiseInstruction() {
        override fun equals(other: Any?): Boolean =
            other is IncludeTxPowerLevel && other.include == include

        override fun hashCode(): Int = include.hashCode()

        override fun toString(): String = "IncludeTxPowerLevel($include)"
    }
}
