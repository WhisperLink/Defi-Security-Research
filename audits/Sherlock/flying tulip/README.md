# Flying Tulip (ftPUT) — 프로토콜 개요

> Sherlock Bug Bounty #248 · https://audits.sherlock.xyz/bug-bounties/248
> 검토 대상: 온체인 verified 소스 (Ethereum 메인넷) · 검토일 2026-07-09

---

## 1. 프로그램 정보

| 항목 | 값 |
|---|---|
| 상태 | LIVE (2026-06-18 시작) |
| 최대 보상 | 1,000,000 USDC |
| Critical | 100,000 → 1,000,000 (직접 영향 자금의 10%, 최대 100만) |
| High | 50,000 → 100,000 |
| Medium | 1,000 → 5,000 |
| 필수 | 실행 가능한 코드형 PoC |
| 익스플로잇 기간 | 팀 대응(pause) 가능 시 피해는 **1시간**으로 한정 |
| "funds affected" | Circuit Breaker의 최대 인출 한도 기준. **버그가 CB를 우회하면 = 전체 TVL** |

**신뢰 모델:** msig admin은 완전 신뢰(구현 업그레이드 포함). 기타 롤(strategyManager, yieldClaimer, keeper 등)은 부분 신뢰. 특권 롤이 프로토콜/유저를 해칠 수 있어도 **informational** 처리 → **공격 시나리오는 비특권 외부 공격자 기준으로만 유효.**

---

## 2. 제품 개요

Flying Tulip의 **ftPUT**는 온체인 풋옵션/담보 상품입니다.

```
사용자 담보 예치 (USDC/USDT/WETH/USDS/USDtb/USDe)
        │  PutManager.invest()
        ▼
   pFT NFT 발행 (PUT 포지션)   ← {ft, amountRemaining, strike, ftPerUSD} 저장
        │
        ├── divest()          → 풋 행사: 담보 회수 (amountRemaining 상한)
        ├── divestUnderlying() → 담보를 positionToken(aToken/vault share)로 in-kind 회수
        └── withdrawFT()       → (transferable 이후) FT 토큰 수령, 담보는 msig가 회수

담보는 ftYieldWrapper(1:1 share)에 예치
        │  keeper가 deploy
        ▼
   전략(Strategy)으로 배포 → Spark ERC4626 / Aave 에서 수익
        ▲
   CircuitBreaker 가 wrapper 인출을 rate-limit (5% / 6h)
```

- **PUT의 본질:** 담보를 넣고 FT 청구권 + 풋(strike에 되팔 권리)을 받음. 각 포지션의 회수 담보는 `amountRemaining`(예치액)으로 상한 → 오라클을 조작해도 예치액 초과 회수 불가.
- **pFT NFT는 transferable 이후 거래 가능** → pFTMarketplace에서 매매.

---

## 3. Scope 컨트랙트 (Ethereum, 17개 주소)

| 컨트랙트 | 주소 | 유형 |
|---|---|---|
| FT (OFT 토큰) | 0x5DD1A7A369e8273371d2DBf9d83356057088082c | LayerZero OFT (Avax/Base/Sonic/BNB 동일 주소) |
| PutManager (impl) | 0x90AE2Cac15F8d58A258f7B4a243657754469922a | UUPS |
| pFT (impl) | 0xc55253Ea84050700E1EfA8878D4A5053b6Bf7c5E | UUPS ERC721 |
| pFTMarketplace (impl) | 0x2a35f9f1B4Ab24F377a06edA61BDa382F7b2Da7F | UUPS |
| YieldClaimer | 0x88432bB6EA62e774cB6d87995CC5277568d01397 | owner/keeper |
| FlyingTulipOracle | 0xC8C895E2be9511006287Ce02E51B5B198AB36793 | Aave 가격 + 경계 |
| CircuitBreaker | 0xCb170bc873b3a1F69F433C25a4b6d0fd4D4D90De | rate limiter |
| ftACL | 0xA09d08E5A850B26d39Ea2a69f8f99Fd8AA1359EB | Merkle 화이트리스트 |
| ftYieldWrapper ×6 | (토큰별, 아래 표) | 담보 vault |
| ERC1967Proxy ×3 | 0xa421…04F2, 0xbA49…ebaA, 0x3124…570c | 프록시 |

### 라이브 프로덕션 설정 (온체인 조회 2026-07-09)

**CircuitBreaker:** maxDrawRate = 5% (5e16 wad), mainWindow = 6h, elasticWindow = 2h, 미pause, 6개 wrapper 전부 protectedContract 등록.

| 풀 | wrapper | TVL | CB 연결 | 전략 | vault |
|---|---|---|---|---|---|
| USDC | 0x095d…bf59 | ~15.75M | ✅ | SparkSavingsStrategy | spUSDC ~$307M |
| WETH | 0x9d96…E305 | ~4,814 | ✅ | SparkSavingsStrategy | spETH ~$170M+ |
| USDT | 0x267d…cB36 | ~18.02M | ✅ | SparkSavingsStrategy | spUSDT ~$455M |
| USDS | 0xA143…7573 | ~2,376 | ❌ (0x0) | AaveStrategy | Aave |
| USDtb | 0xE527…97b6 | ~110 | ❌ (0x0) | AaveStrategy | Aave |
| USDe | 0xe688…5625 | ~71,944 | ❌ (0x0) | AaveStrategy | Aave |

> ⚠️ **스코프 유의:** 자금 대부분(대형 3풀)을 실제 운용하는 `SparkSavingsStrategy`는 Sherlock 스코프 파일 트리(전략은 `AaveStrategy.sol`만 명시)에 **없습니다.** (→ findings FT-04)
> 3개 Spark vault는 모두 **내부 회계**(`totalAssets ≫ 자체 토큰 잔액`) → donation으로 share 가격 조작 불가.

---

## 4. 체인 & 토큰

- **체인:** Ethereum, Base, BSC, Avalanche, Sonic. **단, ftPUT 시스템(PutManager/wrapper/전략)은 Ethereum 전용**이고 타 체인엔 FT OFT 토큰만 존재.
- **토큰:** wrapped native(wETH/wBNB 등), USDC, USDT, USDS, USDTB, USDE (네트워크별 `deployments.toml`이 판정 기준).
- **FT 토큰:** LayerZero OFT, Sonic(chainid 146)에서만 100억 초기 발행, 크로스체인 mint/burn.

---

## 5. 알려진 이슈 (범위 제외)

github.com/flyingtulipdotcom/security · `KNOWN_ISSUES.md` — 아래는 이미 수용된 이슈로 **중복/무효**:

- **PM-01** 저decimal 토큰 소액 반올림 dust · **PM-02** 온체인 손실 미처리 · **PM-03** `invest()` 슬리피지 부재
- **SM-01~04** 타임락·strategyManager·cap front-run·비어있지 않은 전략 제거
- **AAVE-01** `availableToWithdraw` 유동성 미확인 · **YC-01** yield claimer 응답성
- **LEV-01** cancel/fill 해시 공유 · **MKT-01~03** 오퍼 스냅샷 미바인딩·stale 리스팅·native payout 실패

---

*자세한 분석은 [analysis.md](analysis.md), 발견/판단은 [findings.md](findings.md), 재현 하네스는 `../fuzz/` 참조.*
