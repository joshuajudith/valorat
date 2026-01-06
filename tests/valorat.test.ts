
import { describe, expect, it } from "vitest";
import { Cl, ClarityType } from "@stacks/transactions";

const CONTRACT = "valorat";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer");
const manager = accounts.get("wallet_1");
const user1 = accounts.get("wallet_2");
const user2 = accounts.get("wallet_3");

if (!deployer || !manager || !user1 || !user2) {
  throw new Error("Missing expected simnet accounts.");
}

const ERR = {
  NOT_AUTHORIZED: 100,
  VAULT_PAUSED: 101,
  ZERO_AMOUNT: 102,
  INSUFFICIENT_SHARES: 103,
  INSUFFICIENT_BALANCE: 104,
  ALREADY_INITIALIZED: 105,
  INVALID_FEE: 106,
  TRANSFER_FAILED: 107,
  WITHDRAWAL_TOO_LARGE: 200,
  DAILY_LIMIT_EXCEEDED: 201,
  CIRCUIT_BREAKER_TRIGGERED: 202,
  COOLDOWN_NOT_EXPIRED: 203,
  INVALID_YIELD_RATE: 204,
};

const initVault = (feeBps = 100) => {
  const { result } = simnet.callPublicFn(
    CONTRACT,
    "initialize",
    [Cl.standardPrincipal(manager), Cl.uint(feeBps)],
    deployer,
  );
  expect(result).toBeOk(Cl.bool(true));
};

const disableYield = () => {
  const { result } = simnet.callPublicFn(CONTRACT, "set-yield-rate", [Cl.uint(0)], manager);
  expect(result).toBeOk(Cl.uint(0));
};

const unwrapUint = (value: unknown) => {
  expect(value).toHaveClarityType(ClarityType.UInt);
  return (value as { value: bigint }).value;
};

describe("valorat vault core flows", () => {
  it("initializes once and stores manager and fee", () => {
    initVault(250);

    expect(simnet.getDataVar(CONTRACT, "vault-manager")).toBePrincipal(manager);
    expect(simnet.getDataVar(CONTRACT, "management-fee-bps")).toBeUint(250);
    expect(simnet.getDataVar(CONTRACT, "is-initialized")).toBeBool(true);

    const secondInit = simnet.callPublicFn(
      CONTRACT,
      "initialize",
      [Cl.standardPrincipal(manager), Cl.uint(100)],
      deployer,
    );
    expect(secondInit.result).toBeErr(Cl.uint(ERR.ALREADY_INITIALIZED));
  });

  it("rejects initialization from non-owner", () => {
    const { result } = simnet.callPublicFn(
      CONTRACT,
      "initialize",
      [Cl.standardPrincipal(manager), Cl.uint(100)],
      user1,
    );
    expect(result).toBeErr(Cl.uint(ERR.NOT_AUTHORIZED));
  });

  it("mints shares 1:1 on first deposit", () => {
    initVault();
    disableYield();

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(1000)], user1);
    expect(deposit.result).toBeOk(Cl.uint(1000));

    expect(simnet.getDataVar(CONTRACT, "total-assets")).toBeUint(1000);
    expect(simnet.getDataVar(CONTRACT, "total-shares")).toBeUint(1000);

    const userInfo = simnet.callReadOnlyFn(
      CONTRACT,
      "get-user-info",
      [Cl.standardPrincipal(user1)],
      user1,
    );
    expect(userInfo.result).toBeOk(
      Cl.tuple({
        shares: Cl.uint(1000),
        "total-deposits": Cl.uint(1000),
        "withdrawable-assets": Cl.uint(1000),
      }),
    );
  });

  it("burns shares on withdrawal and returns net amount", () => {
    initVault();
    disableYield();

    const limits = simnet.callPublicFn(
      CONTRACT,
      "set-withdrawal-limits",
      [Cl.uint(1_000_000), Cl.uint(5000)],
      manager,
    );
    expect(limits.result).toBeOk(Cl.bool(true));

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(1000)], user1);
    expect(deposit.result).toBeOk(Cl.uint(1000));

    const withdraw = simnet.callPublicFn(CONTRACT, "withdraw", [Cl.uint(500)], user1);
    expect(withdraw.result).toBeOk(Cl.uint(495));

    expect(simnet.getDataVar(CONTRACT, "total-assets")).toBeUint(500);
    expect(simnet.getDataVar(CONTRACT, "total-shares")).toBeUint(500);

    const userInfo = simnet.callReadOnlyFn(
      CONTRACT,
      "get-user-info",
      [Cl.standardPrincipal(user1)],
      user1,
    );
    expect(userInfo.result).toBeOk(
      Cl.tuple({
        shares: Cl.uint(500),
        "total-deposits": Cl.uint(1000),
        "withdrawable-assets": Cl.uint(500),
      }),
    );
  });

  it("blocks deposits while paused", () => {
    initVault();
    disableYield();

    const paused = simnet.callPublicFn(CONTRACT, "pause-vault", [], manager);
    expect(paused.result).toBeOk(Cl.bool(true));

    const blocked = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(100)], user1);
    expect(blocked.result).toBeErr(Cl.uint(ERR.VAULT_PAUSED));

    const unpaused = simnet.callPublicFn(CONTRACT, "unpause-vault", [], manager);
    expect(unpaused.result).toBeOk(Cl.bool(true));

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(100)], user1);
    expect(deposit.result).toBeOk(Cl.uint(100));
  });

  it("restricts manager-only configuration", () => {
    initVault();

    const notManager = simnet.callPublicFn(
      CONTRACT,
      "set-management-fee",
      [Cl.uint(200)],
      user2,
    );
    expect(notManager.result).toBeErr(Cl.uint(ERR.NOT_AUTHORIZED));

    const updated = simnet.callPublicFn(
      CONTRACT,
      "set-management-fee",
      [Cl.uint(200)],
      manager,
    );
    expect(updated.result).toBeOk(Cl.uint(200));
    expect(simnet.getDataVar(CONTRACT, "management-fee-bps")).toBeUint(200);
  });

  it("enforces daily withdrawal limits", () => {
    initVault();
    disableYield();

    const limits = simnet.callPublicFn(
      CONTRACT,
      "set-withdrawal-limits",
      [Cl.uint(1500), Cl.uint(5000)],
      manager,
    );
    expect(limits.result).toBeOk(Cl.bool(true));

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(5000)], user1);
    expect(deposit.result).toBeOk(Cl.uint(5000));

    const first = simnet.callPublicFn(CONTRACT, "withdraw", [Cl.uint(1000)], user1);
    expect(first.result).toBeOk(Cl.uint(990));

    const second = simnet.callPublicFn(CONTRACT, "withdraw", [Cl.uint(600)], user1);
    expect(second.result).toBeErr(Cl.uint(ERR.DAILY_LIMIT_EXCEEDED));
  });

  it("enforces single withdrawal caps", () => {
    initVault();
    disableYield();

    const limits = simnet.callPublicFn(
      CONTRACT,
      "set-withdrawal-limits",
      [Cl.uint(100000), Cl.uint(1000)],
      manager,
    );
    expect(limits.result).toBeOk(Cl.bool(true));

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(10000)], user1);
    expect(deposit.result).toBeOk(Cl.uint(10000));

    const oversized = simnet.callPublicFn(CONTRACT, "withdraw", [Cl.uint(2000)], user1);
    expect(oversized.result).toBeErr(Cl.uint(ERR.WITHDRAWAL_TOO_LARGE));
  });

  it("accrues yield after blocks elapse", () => {
    initVault();

    const deposit = simnet.callPublicFn(CONTRACT, "deposit", [Cl.uint(1_000_000_000)], user1);
    expect(deposit.result).toBeOk(Cl.uint(1_000_000_000));

    const beforeAssets = unwrapUint(simnet.getDataVar(CONTRACT, "total-assets"));

    for (let i = 0; i < 100; i += 1) {
      simnet.mineBlock([]);
    }

    const yieldCall = simnet.callPublicFn(CONTRACT, "update-yield", [], user1);
    expect(yieldCall.result).toHaveClarityType(ClarityType.ResponseOk);
    const yieldValue = (yieldCall.result as { value: { value: bigint } }).value;
    expect(yieldValue).toHaveClarityType(ClarityType.UInt);
    expect(yieldValue.value).toBeGreaterThan(0n);

    const afterAssets = unwrapUint(simnet.getDataVar(CONTRACT, "total-assets"));
    expect(afterAssets).toBeGreaterThan(beforeAssets);
  });
});
