#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name        = "[L4D2] MG Spawner",
    author      = "RenardDev",
    description = "Spawn mounted minigun / 50cal at crosshair",
    version     = "1.0.1",
    url         = "https://github.com/RenardDev/L4D2-MGSpawner"
};

// ================================================================
// Constants
// ================================================================

#define PI 3.14159265358979323846

#define CHAT_PREFIX "[MG]"

#define MAX_ALLOWED              64
#define DELETE_NEAREST_DISTANCE  250.0
#define MIN_DISTANCE_TO_PLAYERS  32.0

#define MODEL_MINIGUN            "models/w_models/weapons/w_minigun.mdl"
#define MODEL_50CAL              "models/w_models/weapons/50cal.mdl"

#define ENTITY_CLASSNAME_MINIGUN "prop_minigun_l4d1"
#define ENTITY_CLASSNAME_50CAL   "prop_minigun"

// ================================================================
// Globals
// ================================================================

int g_nSpawnedGunEntityReferenceBySlot[MAX_ALLOWED];
int g_nSpawnedGunOwnerClientBySlot[MAX_ALLOWED];
int g_nSpawnedGunSerialNumberBySlot[MAX_ALLOWED];
int g_nSpawnedGunSerialNumberGenerator = 0;

Handle g_hSpawnedGunExpirationTimerBySlot[MAX_ALLOWED];

ConVar g_cvMountedGunLimitPerPlayer;
ConVar g_cvMountedGunLifetimeSeconds;
ConVar g_cvMountedGun360;
ConVar g_cvMountedGunDisableCollision;

int g_nClientUsingGunEntityReferenceByClient[MAXPLAYERS + 1];

// ================================================================
// Load checks
// ================================================================

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] szError, int nErrorMax) {
    if (GetEngineVersion() != Engine_Left4Dead2) {
        strcopy(szError, nErrorMax, "Plugin only supports Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

// ================================================================
// Leaf-level helpers
// ================================================================

static bool IsValidEntityReference(int nEntityReference) {
    return (nEntityReference != 0) && (EntRefToEntIndex(nEntityReference) != INVALID_ENT_REFERENCE);
}

static float GetAngleRadians(const float vecAnglesA[3], const float vecAnglesB[3]) {
    float vecDirA[3];
    float vecDirB[3];

    GetAngleVectors(vecAnglesA, vecDirA, NULL_VECTOR, NULL_VECTOR);
    GetAngleVectors(vecAnglesB, vecDirB, NULL_VECTOR, NULL_VECTOR);

    float flLenProd = GetVectorLength(vecDirA) * GetVectorLength(vecDirB);
    if (flLenProd <= 0.000001) {
        return 0.0;
    }

    float flCos = GetVectorDotProduct(vecDirA, vecDirB) / flLenProd;

    if (flCos > 1.0) {
        flCos = 1.0;
    } else if (flCos < -1.0) {
        flCos = -1.0;
    }

    return ArcCosine(flCos);
}

// ================================================================
// Command gating
// ================================================================

static bool RequireAliveInGameClient(int nClient) {
    if ((nClient <= 0) || (nClient > MaxClients) || !IsClientInGame(nClient)) {
        ReplyToCommand(nClient, "%s Use in-game", CHAT_PREFIX);
        return false;
    }

    if (!IsPlayerAlive(nClient)) {
        ReplyToCommand(nClient, "%s Only alive players can use this command", CHAT_PREFIX);
        return false;
    }

    return true;
}

// ================================================================
// Slot helpers
// ================================================================

static void CancelExpirationTimer(int nSlotIndex) {
    if ((nSlotIndex < 0) || (nSlotIndex >= MAX_ALLOWED)) {
        return;
    }

    if (g_hSpawnedGunExpirationTimerBySlot[nSlotIndex] != null) {
        KillTimer(g_hSpawnedGunExpirationTimerBySlot[nSlotIndex]);
        g_hSpawnedGunExpirationTimerBySlot[nSlotIndex] = null;
    }
}

static void CleanupInvalidSlots() {
    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        int nEntityRef = g_nSpawnedGunEntityReferenceBySlot[nSlotIndex];

        if ((nEntityRef != 0) && !IsValidEntityReference(nEntityRef)) {
            CancelExpirationTimer(nSlotIndex);

            g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = 0;
            g_nSpawnedGunOwnerClientBySlot[nSlotIndex] = 0;
            g_nSpawnedGunSerialNumberBySlot[nSlotIndex] = 0;
        }
    }
}

static int CountOwnedByClient(int nClient) {
    CleanupInvalidSlots();

    int nOwnedCount = 0;

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        if ((g_nSpawnedGunOwnerClientBySlot[nSlotIndex] == nClient) && IsValidEntityReference(g_nSpawnedGunEntityReferenceBySlot[nSlotIndex])) {
            nOwnedCount++;
        }
    }

    return nOwnedCount;
}

static void ClearClientUsingGunReferenceEverywhere(int nEntityReference) {
    if (nEntityReference == 0) {
        return;
    }

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (g_nClientUsingGunEntityReferenceByClient[nClient] == nEntityReference) {
            g_nClientUsingGunEntityReferenceByClient[nClient] = 0;
        }
    }
}

static void DeleteSlot(int nSlotIndex) {
    if ((nSlotIndex < 0) || (nSlotIndex >= MAX_ALLOWED)) {
        return;
    }

    CancelExpirationTimer(nSlotIndex);

    int nEntityReference = g_nSpawnedGunEntityReferenceBySlot[nSlotIndex];

    if (IsValidEntityReference(nEntityReference)) {
        ClearClientUsingGunReferenceEverywhere(nEntityReference);

        int nEntityIndex = EntRefToEntIndex(nEntityReference);

        if ((nEntityIndex > 0) && IsValidEntity(nEntityIndex) && IsValidEdict(nEntityIndex)) {
            int nOwnerClient = GetEntPropEnt(nEntityIndex, Prop_Send, "m_owner");

            if ((nOwnerClient > 0) && (nOwnerClient <= MaxClients) && IsClientInGame(nOwnerClient)) {
                SetEntPropEnt(nOwnerClient, Prop_Send, "m_usingMountedWeapon", 0);
                SetEntPropEnt(nOwnerClient, Prop_Send, "m_hUseEntity", -1);
            }

            SetEntPropEnt(nEntityIndex, Prop_Send, "m_owner", -1);
            RemoveEntity(nEntityIndex);
        }
    }

    g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = 0;
    g_nSpawnedGunOwnerClientBySlot[nSlotIndex] = 0;
    g_nSpawnedGunSerialNumberBySlot[nSlotIndex] = 0;
}

static void ResetAllSpawnedGuns() {
    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        DeleteSlot(nSlotIndex);
    }
}

static int FindSlotIndexByEntityReference(int nEntityReference) {
    CleanupInvalidSlots();

    if (!IsValidEntityReference(nEntityReference)) {
        return -1;
    }

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        if (g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] == nEntityReference) {
            return nSlotIndex;
        }
    }

    return -1;
}

static bool IsSpawnedGunEntityReference(int nEntityReference) {
    return FindSlotIndexByEntityReference(nEntityReference) != -1;
}

static int FindFreeSlotIndex() {
    CleanupInvalidSlots();

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        if (!IsValidEntityReference(g_nSpawnedGunEntityReferenceBySlot[nSlotIndex])) {
            return nSlotIndex;
        }
    }

    return -1;
}

// ================================================================
// Placement checks
// ================================================================

static float GetSquaredDistancePointToAabb(const float vecPoint[3], const float vecAabbMin[3], const float vecAabbMax[3]) {
    float flDx = 0.0;
    float flDy = 0.0;
    float flDz = 0.0;

    if (vecPoint[0] < vecAabbMin[0]) {
        flDx = vecAabbMin[0] - vecPoint[0];
    } else if (vecPoint[0] > vecAabbMax[0]) {
        flDx = vecPoint[0] - vecAabbMax[0];
    }

    if (vecPoint[1] < vecAabbMin[1]) {
        flDy = vecAabbMin[1] - vecPoint[1];
    } else if (vecPoint[1] > vecAabbMax[1]) {
        flDy = vecPoint[1] - vecAabbMax[1];
    }

    if (vecPoint[2] < vecAabbMin[2]) {
        flDz = vecAabbMin[2] - vecPoint[2];
    } else if (vecPoint[2] > vecAabbMax[2]) {
        flDz = vecPoint[2] - vecAabbMax[2];
    }

    return (flDx * flDx) + (flDy * flDy) + (flDz * flDz);
}

static bool IsPlacementTooCloseToSurvivors(const float vecPlacementPosition[3]) {
    if (MIN_DISTANCE_TO_PLAYERS <= 0.0) {
        return false;
    }

    float flMinDistanceSquared = MIN_DISTANCE_TO_PLAYERS * MIN_DISTANCE_TO_PLAYERS;

    float vecPlayerAbsOrigin[3];
    float vecPlayerMins[3];
    float vecPlayerMaxs[3];

    float vecAabbMin[3];
    float vecAabbMax[3];

    for (int nOtherClient = 1; nOtherClient <= MaxClients; nOtherClient++) {
        if (!IsClientInGame(nOtherClient)) {
            continue;
        }

        if (!IsPlayerAlive(nOtherClient)) {
            continue;
        }

        if (GetClientTeam(nOtherClient) != 2) {
            continue;
        }

        GetClientAbsOrigin(nOtherClient, vecPlayerAbsOrigin);

        GetEntPropVector(nOtherClient, Prop_Send, "m_vecMins", vecPlayerMins);
        GetEntPropVector(nOtherClient, Prop_Send, "m_vecMaxs", vecPlayerMaxs);

        vecAabbMin[0] = vecPlayerAbsOrigin[0] + vecPlayerMins[0];
        vecAabbMin[1] = vecPlayerAbsOrigin[1] + vecPlayerMins[1];
        vecAabbMin[2] = vecPlayerAbsOrigin[2] + vecPlayerMins[2];

        vecAabbMax[0] = vecPlayerAbsOrigin[0] + vecPlayerMaxs[0];
        vecAabbMax[1] = vecPlayerAbsOrigin[1] + vecPlayerMaxs[1];
        vecAabbMax[2] = vecPlayerAbsOrigin[2] + vecPlayerMaxs[2];

        float flDistanceSquared = GetSquaredDistancePointToAabb(vecPlacementPosition, vecAabbMin, vecAabbMax);
        if (flDistanceSquared < flMinDistanceSquared) {
            return true;
        }
    }

    return false;
}

// ================================================================
// Spawn helpers
// ================================================================

static bool TraceFilterDoNotHitClient(int nEntityIndex, int nContentsMask, int nClient) {
    return nEntityIndex != nClient;
}

public Action TimerExpireSpawnedGun(Handle hTimer, any nTimerData) {
    DataPack hDataPack = view_as<DataPack>(nTimerData);
    hDataPack.Reset();

    int nSlotIndex = hDataPack.ReadCell();
    int nSerialNumber = hDataPack.ReadCell();

    if ((nSlotIndex < 0) || (nSlotIndex >= MAX_ALLOWED)) {
        return Plugin_Continue;
    }

    g_hSpawnedGunExpirationTimerBySlot[nSlotIndex] = null;

    if (nSerialNumber != g_nSpawnedGunSerialNumberBySlot[nSlotIndex]) {
        return Plugin_Continue;
    }

    DeleteSlot(nSlotIndex);
    return Plugin_Continue;
}

static void ApplyMountedGunRotationLimits(int nEntityIndex) {
    DispatchKeyValueFloat(nEntityIndex, "MaxPitch", 360.0);
    DispatchKeyValueFloat(nEntityIndex, "MinPitch", -360.0);

    if (g_cvMountedGun360.BoolValue) {
        DispatchKeyValueFloat(nEntityIndex, "MaxYaw", 360.0);
        DispatchKeyValueFloat(nEntityIndex, "MinYaw", -360.0);
    } else {
        DispatchKeyValueFloat(nEntityIndex, "MaxYaw", 90.0);
        DispatchKeyValueFloat(nEntityIndex, "MinYaw", -90.0);
    }
}

static void SpawnMountedGunEntity(int nClient, const float vecPosition[3], const float vecAngles[3], int nGunType) {
    int nSlotIndex = FindFreeSlotIndex();
    if (nSlotIndex < 0) {
        return;
    }

    int nEntityIndex = -1;

    if (nGunType == 0) {
        nEntityIndex = CreateEntityByName(ENTITY_CLASSNAME_MINIGUN);
        if (nEntityIndex == -1) {
            return;
        }

        SetEntityModel(nEntityIndex, MODEL_MINIGUN);
    } else {
        nEntityIndex = CreateEntityByName(ENTITY_CLASSNAME_50CAL);
        if (nEntityIndex == -1) {
            return;
        }

        SetEntityModel(nEntityIndex, MODEL_50CAL);
    }

    ApplyMountedGunRotationLimits(nEntityIndex);
    TeleportEntity(nEntityIndex, vecPosition, vecAngles, NULL_VECTOR);

    if (g_cvMountedGunDisableCollision.BoolValue) {
        SetEntProp(nEntityIndex, Prop_Send, "m_CollisionGroup", 2);
    }

    DispatchSpawn(nEntityIndex);
    ActivateEntity(nEntityIndex);

    g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = EntIndexToEntRef(nEntityIndex);
    g_nSpawnedGunOwnerClientBySlot[nSlotIndex] = nClient;

    int nSerialNumber = ++g_nSpawnedGunSerialNumberGenerator;
    g_nSpawnedGunSerialNumberBySlot[nSlotIndex] = nSerialNumber;

    float flLifetimeSeconds = float(g_cvMountedGunLifetimeSeconds.IntValue);
    if (flLifetimeSeconds > 0.0) {
        CancelExpirationTimer(nSlotIndex);

        DataPack hDataPack = new DataPack();
        hDataPack.WriteCell(nSlotIndex);
        hDataPack.WriteCell(nSerialNumber);

        g_hSpawnedGunExpirationTimerBySlot[nSlotIndex] = CreateTimer(
            flLifetimeSeconds,
            TimerExpireSpawnedGun,
            hDataPack,
            TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE
        );
    }
}

static void PlaceMountedGunFromCrosshair(int nClient, int nGunType) {
    float vecEyeAngles[3];
    float vecEyePosition[3];

    GetClientEyeAngles(nClient, vecEyeAngles);
    GetClientEyePosition(nClient, vecEyePosition);

    Handle hTrace = TR_TraceRayFilterEx(vecEyePosition, vecEyeAngles, MASK_SHOT, RayType_Infinite, TraceFilterDoNotHitClient, nClient);
    if (!TR_DidHit(hTrace)) {
        delete hTrace;
        return;
    }

    float vecHitPosition[3];
    TR_GetEndPosition(vecHitPosition, hTrace);
    delete hTrace;

    vecEyeAngles[0] = 0.0;
    vecEyeAngles[2] = 0.0;

    if (!g_cvMountedGunDisableCollision.BoolValue) {
        if (IsPlacementTooCloseToSurvivors(vecHitPosition)) {
            PrintToChat(nClient, "%s Too close to the survivor", CHAT_PREFIX);
            return;
        }
    }

    SpawnMountedGunEntity(nClient, vecHitPosition, vecEyeAngles, nGunType);
}

// ================================================================
// Spawned-gun recreate logic (360 fix)
// ================================================================

static void RecreateSpawnedGunByEntityReference(int nEntityReference) {
    int nSlotIndex = FindSlotIndexByEntityReference(nEntityReference);
    if (nSlotIndex == -1) {
        return;
    }

    if (!IsValidEntityReference(nEntityReference)) {
        DeleteSlot(nSlotIndex);
        return;
    }

    int nOldEntityIndex = EntRefToEntIndex(nEntityReference);
    if ((nOldEntityIndex <= 0) || !IsValidEntity(nOldEntityIndex)) {
        DeleteSlot(nSlotIndex);
        return;
    }

    char szClassName[64];
    GetEdictClassname(nOldEntityIndex, szClassName, sizeof(szClassName));

    char szModelName[PLATFORM_MAX_PATH];
    GetEntPropString(nOldEntityIndex, Prop_Data, "m_ModelName", szModelName, sizeof(szModelName));

    float vecPosition[3];
    GetEntPropVector(nOldEntityIndex, Prop_Send, "m_vecOrigin", vecPosition);

    float vecAngles[3];
    GetEntPropVector(nOldEntityIndex, Prop_Send, "m_angRotation", vecAngles);

    RemoveEntity(nOldEntityIndex);

    int nNewEntityIndex = CreateEntityByName(szClassName);
    if (nNewEntityIndex == -1) {
        CancelExpirationTimer(nSlotIndex);

        g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = 0;
        g_nSpawnedGunOwnerClientBySlot[nSlotIndex] = 0;
        g_nSpawnedGunSerialNumberBySlot[nSlotIndex] = 0;
        return;
    }

    SetEntityModel(nNewEntityIndex, szModelName);

    ApplyMountedGunRotationLimits(nNewEntityIndex);
    TeleportEntity(nNewEntityIndex, vecPosition, vecAngles, NULL_VECTOR);

    if (g_cvMountedGunDisableCollision.BoolValue) {
        SetEntProp(nNewEntityIndex, Prop_Send, "m_CollisionGroup", 2);
    }

    DispatchSpawn(nNewEntityIndex);
    ActivateEntity(nNewEntityIndex);

    g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = EntIndexToEntRef(nNewEntityIndex);
}

// ================================================================
// OnPlayerRunCmd (360 rotation enforcement)
// ================================================================

public Action OnPlayerRunCmd(int nClient, int& nButtons, int& nImpulse, float vecVelocity[3], float vecAngles[3], int& nWeapon) {
    if (!g_cvMountedGun360.BoolValue) {
        return Plugin_Continue;
    }

    if ((nClient <= 0) || (nClient > MaxClients)) {
        return Plugin_Continue;
    }

    if (!IsClientInGame(nClient)) {
        return Plugin_Continue;
    }

    if (IsFakeClient(nClient)) {
        return Plugin_Continue;
    }

    if (!IsPlayerAlive(nClient)) {
        return Plugin_Continue;
    }

    if (GetClientTeam(nClient) != 2) {
        return Plugin_Continue;
    }

    int nPreviousUseEntityReference = g_nClientUsingGunEntityReferenceByClient[nClient];

    int nUseEntityIndex = GetEntPropEnt(nClient, Prop_Send, "m_hUseEntity");
    int nUseEntityReference = 0;

    if (nUseEntityIndex > 0) {
        nUseEntityReference = EntIndexToEntRef(nUseEntityIndex);
    }

    if ((nPreviousUseEntityReference != 0) && (nUseEntityReference != nPreviousUseEntityReference)) {
        if (IsSpawnedGunEntityReference(nPreviousUseEntityReference)) {
            RecreateSpawnedGunByEntityReference(nPreviousUseEntityReference);
        }

        g_nClientUsingGunEntityReferenceByClient[nClient] = 0;
    }

    if (nUseEntityIndex <= 0) {
        return Plugin_Continue;
    }

    if (!IsSpawnedGunEntityReference(nUseEntityReference)) {
        g_nClientUsingGunEntityReferenceByClient[nClient] = 0;
        return Plugin_Continue;
    }

    if (nUseEntityReference != nPreviousUseEntityReference) {
        ApplyMountedGunRotationLimits(nUseEntityIndex);
        g_nClientUsingGunEntityReferenceByClient[nClient] = nUseEntityReference;
    }

    float vecClientEyeAngles[3];
    GetClientEyeAngles(nClient, vecClientEyeAngles);

    vecClientEyeAngles[0] = 0.0;
    vecClientEyeAngles[2] = 0.0;

    float vecGunAngles[3];
    GetEntPropVector(nUseEntityIndex, Prop_Send, "m_angRotation", vecGunAngles);

    vecGunAngles[0] = 0.0;
    vecGunAngles[2] = 0.0;

    float flAngleDegrees = (GetAngleRadians(vecClientEyeAngles, vecGunAngles) * 180.0) / PI;
    if (flAngleDegrees > 89.0) {
        TeleportEntity(nUseEntityIndex, NULL_VECTOR, vecClientEyeAngles, NULL_VECTOR);
    }

    return Plugin_Continue;
}

// ================================================================
// Commands
// ================================================================

public Action CommandSpawnMountedGun(int nClient, int nArgs) {
    if (!RequireAliveInGameClient(nClient)) {
        return Plugin_Handled;
    }

    int nLimitPerPlayer = g_cvMountedGunLimitPerPlayer.IntValue;
    if ((nLimitPerPlayer > 0) && (CountOwnedByClient(nClient) >= nLimitPerPlayer)) {
        PrintToChat(nClient, "%s Limit reached (%d)", CHAT_PREFIX, nLimitPerPlayer);
        return Plugin_Handled;
    }

    int nGunType = 0;

    if (nArgs >= 1) {
        char szArg[8];
        GetCmdArg(1, szArg, sizeof(szArg));
        nGunType = (StringToInt(szArg) != 0) ? 1 : 0;
    }

    PlaceMountedGunFromCrosshair(nClient, nGunType);
    return Plugin_Handled;
}

public Action CommandListMountedGuns(int nClient, int nArgs) {
    if (!RequireAliveInGameClient(nClient)) {
        return Plugin_Handled;
    }

    CleanupInvalidSlots();

    int nTotalCount = 0;
    float vecPosition[3];

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        int nEntityRef = g_nSpawnedGunEntityReferenceBySlot[nSlotIndex];
        if (!IsValidEntityReference(nEntityRef)) {
            continue;
        }

        int nEntityIndex = EntRefToEntIndex(nEntityRef);
        if ((nEntityIndex <= 0) || !IsValidEntity(nEntityIndex)) {
            continue;
        }

        GetEntPropVector(nEntityIndex, Prop_Data, "m_vecOrigin", vecPosition);

        nTotalCount++;

        PrintToChat(
            nClient,
            "%s %d) (Owner:%d) %.1f %.1f %.1f",
            CHAT_PREFIX,
            nTotalCount,
            g_nSpawnedGunOwnerClientBySlot[nSlotIndex],
            vecPosition[0], vecPosition[1], vecPosition[2]
        );
    }

    PrintToChat(nClient, "%s Total: %d", CHAT_PREFIX, nTotalCount);
    return Plugin_Handled;
}

public Action CommandDeleteNearestGun(int nClient, int nArgs) {
    if (!RequireAliveInGameClient(nClient)) {
        return Plugin_Handled;
    }

    CleanupInvalidSlots();

    float vecEyeAngles[3];
    float vecEyePosition[3];

    GetClientEyeAngles(nClient, vecEyeAngles);
    GetClientEyePosition(nClient, vecEyePosition);

    Handle hTrace = TR_TraceRayFilterEx(vecEyePosition, vecEyeAngles, MASK_SHOT, RayType_Infinite, TraceFilterDoNotHitClient, nClient);
    if (!TR_DidHit(hTrace)) {
        delete hTrace;
        PrintToChat(nClient, "%s No hit under crosshair", CHAT_PREFIX);
        return Plugin_Handled;
    }

    float vecAimPosition[3];
    TR_GetEndPosition(vecAimPosition, hTrace);
    delete hTrace;

    int nBestSlotIndex = -1;
    float flBestDistance = DELETE_NEAREST_DISTANCE;

    float vecEntityPosition[3];

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        int nEntityRef = g_nSpawnedGunEntityReferenceBySlot[nSlotIndex];
        if (!IsValidEntityReference(nEntityRef)) {
            continue;
        }

        int nEntityIndex = EntRefToEntIndex(nEntityRef);
        if ((nEntityIndex <= 0) || !IsValidEntity(nEntityIndex)) {
            continue;
        }

        GetEntPropVector(nEntityIndex, Prop_Send, "m_vecOrigin", vecEntityPosition);

        float flDistance = GetVectorDistance(vecAimPosition, vecEntityPosition);
        if (flDistance < flBestDistance) {
            flBestDistance = flDistance;
            nBestSlotIndex = nSlotIndex;
        }
    }

    if (nBestSlotIndex == -1) {
        PrintToChat(nClient, "%s No MG near crosshair (<=%.0f)", CHAT_PREFIX, DELETE_NEAREST_DISTANCE);
        return Plugin_Handled;
    }

    if (g_nSpawnedGunOwnerClientBySlot[nBestSlotIndex] != nClient) {
        PrintToChat(nClient, "%s You can delete only your own MG", CHAT_PREFIX);
        return Plugin_Handled;
    }

    DeleteSlot(nBestSlotIndex);
    PrintToChat(nClient, "%s Deleted", CHAT_PREFIX);
    return Plugin_Handled;
}

public Action CommandClearMyMountedGuns(int nClient, int nArgs) {
    if (!RequireAliveInGameClient(nClient)) {
        return Plugin_Handled;
    }

    CleanupInvalidSlots();

    int nRemovedCount = 0;

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        if ((g_nSpawnedGunOwnerClientBySlot[nSlotIndex] == nClient) && IsValidEntityReference(g_nSpawnedGunEntityReferenceBySlot[nSlotIndex])) {
            DeleteSlot(nSlotIndex);
            nRemovedCount++;
        }
    }

    PrintToChat(nClient, "%s Cleared: %d", CHAT_PREFIX, nRemovedCount);
    return Plugin_Handled;
}

// ================================================================
// Events + Lifecycle
// ================================================================

public void EventRoundEnd(Event hEvent, const char[] szName, bool bDontBroadcast) {
    ResetAllSpawnedGuns();

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        g_nClientUsingGunEntityReferenceByClient[nClient] = 0;
    }
}

public void OnPluginStart() {
    g_cvMountedGunLimitPerPlayer = CreateConVar(
        "l4d2_mg_limit_per_player",
        "1",
        "Max MG per player (0 = unlimited)",
        FCVAR_NOTIFY
    );

    g_cvMountedGunLifetimeSeconds = CreateConVar(
        "l4d2_mg_lifetime_seconds",
        "900",
        "Seconds until placed MG auto-deletes (0 = never)",
        FCVAR_NOTIFY
    );

    g_cvMountedGun360 = CreateConVar(
        "l4d2_mg_360",
        "1",
        "Enable 360 mounted gun rotation fix (1=on, 0=off)",
        FCVAR_NOTIFY
    );

    g_cvMountedGunDisableCollision = CreateConVar(
        "l4d2_mg_disable_collision",
        "1",
        "Disable mounted gun collision (1=on, 0=off)",
        FCVAR_NOTIFY
    );

    RegConsoleCmd("sm_mg",      CommandSpawnMountedGun,    "Spawn MG at crosshair. Usage: sm_mg [0|1] (0=minigun, 1=50cal)");
    RegConsoleCmd("sm_mglist",  CommandListMountedGuns,    "List spawned MG positions");
    RegConsoleCmd("sm_mgdel",   CommandDeleteNearestGun,   "Delete nearest spawned MG near crosshair (<=250 units)");
    RegConsoleCmd("sm_mgclear", CommandClearMyMountedGuns, "Delete your spawned MGs");

    HookEvent("round_end", EventRoundEnd, EventHookMode_PostNoCopy);

    g_nSpawnedGunSerialNumberGenerator = 0;

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        g_nSpawnedGunEntityReferenceBySlot[nSlotIndex] = 0;
        g_nSpawnedGunOwnerClientBySlot[nSlotIndex] = 0;
        g_nSpawnedGunSerialNumberBySlot[nSlotIndex] = 0;
        g_hSpawnedGunExpirationTimerBySlot[nSlotIndex] = null;
    }

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        g_nClientUsingGunEntityReferenceByClient[nClient] = 0;
    }
}

public void OnMapStart() {
    PrecacheModel(MODEL_MINIGUN, true);
    PrecacheModel(MODEL_50CAL, true);
}

public void OnMapEnd() {
    ResetAllSpawnedGuns();
}

public void OnPluginEnd() {
    ResetAllSpawnedGuns();
}

public void OnClientDisconnect(int nClient) {
    if ((nClient <= 0) || (nClient > MaxClients)) {
        return;
    }

    g_nClientUsingGunEntityReferenceByClient[nClient] = 0;

    CleanupInvalidSlots();

    for (int nSlotIndex = 0; nSlotIndex < MAX_ALLOWED; nSlotIndex++) {
        if ((g_nSpawnedGunOwnerClientBySlot[nSlotIndex] == nClient) && IsValidEntityReference(g_nSpawnedGunEntityReferenceBySlot[nSlotIndex])) {
            DeleteSlot(nSlotIndex);
        }
    }
}
