package io.godstone.mesh.transport

import io.godstone.mesh.wire.v2.FrameV2
import java.util.UUID

/**
 * T10: the canonical GATT profile of a GodStone peripheral.
 *
 * One service and its three characteristics are defined once, as generated
 * values from the wire contract (wire/wire_v2.yaml through FrameV2), and
 * every installer, every resolver and every controller in this tree reads
 * these values. No runtime code may re-roll its own UUID constants:
 *
 *   service   FrameV2.SERVICE_UUID   (A001)
 *   inbox     FrameV2.INBOX_UUID     (A002)  W | WR | N
 *   digest    FrameV2.DIGEST_UUID    (A003)  R | N
 *   link info FrameV2.LINK_INFO_UUID (A004)  R | W
 *
 * The historical, hand-rolled FD short-form characteristic values
 * (0000FD01-... inbox, 0000FD02-... digest) are the non-shipping legacy
 * profile: this contract never names them and the provisioning gate rejects
 * trees that carry them. The transport does not dual-register (advertise or
 * scan for) both protocols; there is no auto-detection.
 *
 * The file is free of android.* imports: the platform bit values below are
 * asserted mirrors of android.bluetooth.BluetoothGattCharacteristic's
 * compile-time constants (SDK 35 facade, verified with javap), so the whole
 * decision surface is inspectable by JVM unit tests.
 */
enum class GattProperty {
    READ,
    WRITE,
    WRITE_NO_RESPONSE,
    NOTIFY
}

/** One installed or installable characteristic of the canonical service tree. */
class ContractCharacteristic(val uuid: UUID, val properties: Set<GattProperty>) {

    override fun equals(other: Any?): Boolean {
        if (other !is ContractCharacteristic) {
            return false
        }
        return other.uuid == uuid && other.properties == properties
    }

    override fun hashCode(): Int = 31 * uuid.hashCode() + properties.hashCode()

    override fun toString(): String = "ContractCharacteristic($uuid, $properties)"
}

/** Result of resolving an inbound GATT tree against the canonical profile. */
sealed class ProvisionCheck {

    /** The tree is exactly the canonical profile. */
    object Match : ProvisionCheck() {
        override fun toString(): String = "ProvisionCheck.Match"
    }

    /** The service itself is not the canonical service (e.g. a legacy FD-base one). */
    class WrongService(val uuid: UUID) : ProvisionCheck() {
        override fun equals(other: Any?): Boolean = other is WrongService && other.uuid == uuid
        override fun hashCode(): Int = uuid.hashCode()
        override fun toString(): String = "ProvisionCheck.WrongService($uuid)"
    }

    /** The tree names a characteristic the contract does not recognise. */
    class Unexpected(val uuid: UUID) : ProvisionCheck() {
        override fun equals(other: Any?): Boolean = other is Unexpected && other.uuid == uuid
        override fun hashCode(): Int = uuid.hashCode()
        override fun toString(): String = "ProvisionCheck.Unexpected($uuid)"
    }

    /** The tree registers one characteristic uuid more than once. */
    class Duplicate(val uuid: UUID) : ProvisionCheck() {
        override fun equals(other: Any?): Boolean = other is Duplicate && other.uuid == uuid
        override fun hashCode(): Int = uuid.hashCode()
        override fun toString(): String = "ProvisionCheck.Duplicate($uuid)"
    }

    /** The tree carries the uuid but not (all) the required properties. */
    class Missing(val uuid: UUID, val required: Set<GattProperty>, val found: Set<GattProperty>) : ProvisionCheck() {
        override fun equals(other: Any?): Boolean =
            other is Missing && other.uuid == uuid && other.required == required && other.found == found

        override fun hashCode(): Int = 31 * (31 * uuid.hashCode() + required.hashCode()) + found.hashCode()

        override fun toString(): String = "ProvisionCheck.Missing($uuid, want=$required, found=$found)"
    }
}

/** Routing decision of the server for one inbound write, by characteristic uuid equality. */
enum class InboundRoute {
    /** The record is a LinkInfo record: it is taken by the link info store, never by the record decoder. */
    TO_LINK_INFO,

    /** The record is a frame record: it enters the record decoder (deframer). */
    TO_DEFRAMER,

    /** Unknown characteristic: answered not supported. */
    NOT_SUPPORTED
}

/**
 * The canonical characteristic set, its resolvers and its mapping helpers.
 *
 * A set is the service uuid plus three named, pairwise distinct roles. The
 * check resolver reports Duplicate first (a tree is a set, never a bag),
 * then Unexpected (any uuid beyond the contract), then Missing (absent
 * characteristic or a gap in the required properties). Match requires every
 * role present exactly once with at least the required properties, and the
 * tree containing nothing beyond the contract.
 */
class RequiredCharacteristicSet(
    val serviceUuid: UUID,
    val inbox: ContractCharacteristic,
    val digest: ContractCharacteristic,
    val linkInfo: ContractCharacteristic
) {

    val characteristics: List<ContractCharacteristic> = listOf(inbox, digest, linkInfo)

    init {
        val roles = listOf(inbox.uuid, digest.uuid, linkInfo.uuid)
        if (roles.size != roles.distinct().size) {
            throw IllegalArgumentException("the three characteristic roles must be pairwise distinct")
        }
    }

    /** Resolve the service itself. */
    fun checkService(uuid: UUID): ProvisionCheck =
        if (uuid == serviceUuid) ProvisionCheck.Match else ProvisionCheck.WrongService(uuid)

    /** Resolve a whole characteristic tree against the set. */
    fun check(tree: List<ContractCharacteristic>): ProvisionCheck {
        val buckets = mutableMapOf<UUID, MutableList<Set<GattProperty>>>()
        for (entry in tree) {
            val bucket = buckets[entry.uuid]
            if (bucket == null) {
                val fresh = mutableListOf<Set<GattProperty>>()
                fresh.add(entry.properties)
                buckets[entry.uuid] = fresh
            } else {
                bucket.add(entry.properties)
            }
        }

        for (role in characteristics) {
            val bucket = buckets[role.uuid]
            if (bucket != null && bucket.size > 1) {
                return ProvisionCheck.Duplicate(role.uuid)
            }
        }

        for (uuid in buckets.keys) {
            var known = false
            for (role in characteristics) {
                if (role.uuid == uuid) {
                    known = true
                }
            }
            if (!known) {
                return ProvisionCheck.Unexpected(uuid)
            }
        }

        for (role in characteristics) {
            val bucket = buckets[role.uuid]
            if (bucket == null) {
                return ProvisionCheck.Missing(role.uuid, role.properties, setOf<GattProperty>())
            }
            val found = bucket[0]
            var gap = false
            for (property in role.properties) {
                if (!found.contains(property)) {
                    gap = true
                }
            }
            if (gap) {
                return ProvisionCheck.Missing(role.uuid, role.properties, found)
            }
        }
        return ProvisionCheck.Match
    }

    /** Convenience for the provisioning gate: true when the tree is the profile. */
    fun accepts(tree: List<ContractCharacteristic>): Boolean = check(tree) is ProvisionCheck.Match

    companion object {

        /**
         * Asserted mirrors of android.bluetooth.BluetoothGattCharacteristic
         * PROPERTY_* (SDK 35 facade; compile-time inlined constants):
         * READ=2, WRITE_NO_RESPONSE=4, WRITE=8, NOTIFY=16.
         */
        const val PROPERTY_READ_BIT: Int = 2
        const val PROPERTY_WRITE_NO_RESPONSE_BIT: Int = 4
        const val PROPERTY_WRITE_BIT: Int = 8
        const val PROPERTY_NOTIFY_BIT: Int = 16

        /**
         * Asserted mirrors of android.bluetooth.BluetoothGattCharacteristic
         * PERMISSION_READ=1 and PERMISSION_WRITE=16.
         */
        const val PERMISSION_READ_BIT: Int = 1
        const val PERMISSION_WRITE_BIT: Int = 16

        /** The one canonical set: generated UUIDs, hand-checked property masks. */
        val MESH: RequiredCharacteristicSet = RequiredCharacteristicSet(
            serviceUuid = FrameV2.SERVICE_UUID,
            inbox = ContractCharacteristic(
                FrameV2.INBOX_UUID,
                setOf(GattProperty.WRITE, GattProperty.WRITE_NO_RESPONSE, GattProperty.NOTIFY)
            ),
            digest = ContractCharacteristic(
                FrameV2.DIGEST_UUID,
                setOf(GattProperty.READ, GattProperty.NOTIFY)
            ),
            linkInfo = ContractCharacteristic(
                FrameV2.LINK_INFO_UUID,
                setOf(GattProperty.READ, GattProperty.WRITE)
            )
        )

        /** Decode a platform property bitmask into the semantic property set. */
        fun propertiesOf(mask: Int): Set<GattProperty> {
            val out = mutableSetOf<GattProperty>()
            if (mask and PROPERTY_READ_BIT != 0) {
                out.add(GattProperty.READ)
            }
            if (mask and PROPERTY_WRITE_BIT != 0) {
                out.add(GattProperty.WRITE)
            }
            if (mask and PROPERTY_WRITE_NO_RESPONSE_BIT != 0) {
                out.add(GattProperty.WRITE_NO_RESPONSE)
            }
            if (mask and PROPERTY_NOTIFY_BIT != 0) {
                out.add(GattProperty.NOTIFY)
            }
            return out
        }

        /** Encode a semantic property set into the platform property bitmask. */
        fun maskOf(properties: Set<GattProperty>): Int {
            var mask = 0
            if (properties.contains(GattProperty.READ)) {
                mask = mask or PROPERTY_READ_BIT
            }
            if (properties.contains(GattProperty.WRITE)) {
                mask = mask or PROPERTY_WRITE_BIT
            }
            if (properties.contains(GattProperty.WRITE_NO_RESPONSE)) {
                mask = mask or PROPERTY_WRITE_NO_RESPONSE_BIT
            }
            if (properties.contains(GattProperty.NOTIFY)) {
                mask = mask or PROPERTY_NOTIFY_BIT
            }
            return mask
        }

        /**
         * Map a property set to the platform permission mask, preserving the
         * historical installation: READ grants PERMISSION_READ, WRITE and
         * WRITE_NO_RESPONSE grant PERMISSION_WRITE, NOTIFY grants no access
         * permission of its own (subscription travels on the CCC descriptor).
         */
        fun permissionsFor(properties: Set<GattProperty>): Int {
            var permissions = 0
            if (properties.contains(GattProperty.READ)) {
                permissions = permissions or PERMISSION_READ_BIT
            }
            if (properties.contains(GattProperty.WRITE) || properties.contains(GattProperty.WRITE_NO_RESPONSE)) {
                permissions = permissions or PERMISSION_WRITE_BIT
            }
            return permissions
        }

        /**
         * The legacy, non-shipping FD short-form profile. The contract never
         * names these values and the resolvers reject trees that carry them.
         */
        fun isLegacyFdValue(uuid: UUID): Boolean {
            val text = uuid.toString()
            return text.startsWith("0000fd")
        }
    }
}
