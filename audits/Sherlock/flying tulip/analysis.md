# Flying Tulip (ftPUT) — 분석 내용

> 방법론: 온체인 verified 소스 정독(정적) + Foundry 불변식/directed 퍼징(동적)
> 결과: **52 tests / 13 suites 전부 통과.** 비특권 공격자의 자금유출 경로 미발견.

---

## 1. 방법론 & 커버리지

1. **소스 확보** — 17개 스코프 주소 + 배포 전략을 Sourcify/Blockscout/Etherscan에서 추출 (private repo `ftPUT` 비공개).
2. **정적 정독** — 9개 코어 컨트랙트 + 2개 전략(4,559 + 405줄) 전수 리뷰.
3. **라이브 검증** — `cast`로 프로덕션 설정(CB 파라미터, wrapper↔전략↔vault, TVL, vault 회계 방식) 실측.
4. **동적 퍼징** — 코어 시스템을 프록시로 배포, 비특권 사용자 관점으로 불변식 퍼징 + directed PoC.

### 커버리지 매트릭스

| 공격 표면 | 방식 | 하네스 | 결과 |
|---|---|---|---|
| 코어 회계 (PutManager/pFT/wrapper) | 6 불변식 + 4 directed | `FTInvariant`, `FTUnit` | ✅ |
| 가격 변환 수학 (전 파라미터) | 순수함수 150k runs | `PricingFuzz` | ✅ |
| CircuitBreaker | 수학 불변식 + 우회 PoC | `CBInvariant` | ✅ |
| Marketplace | 보존 불변식 + 서명 오퍼 | `MarketInvariant`, `MarketDirected` | ✅ |
| FT OFT (LayerZero) | pause·permit·burn·공급 | `FTOFT` | ✅ |
| 전략: Spark ERC4626 | end-to-end + inflation PoC | `SparkInvariant`, `SparkInflationPoC`, `SparkChar` | ✅ |
| 전략: 다중 전략 인출 루프 | 3전략 30k 콜 | `MultiStrategy` | ✅ |

---

## 2. 컨트랙트별 핵심 분석

### PutManager
- `invest` → pFT.mint, `divest`/`divestUnderlying`/`withdrawFT`가 청산 경로.
- **핵심 안전장치:** pFT가 `amountDivested ≤ amountRemaining`, `amount ≤ ft`로 상한. `amountRemaining`은 예치액에서만 시작해 단조감소 → **오라클 조작으로도 포지션당 예치액 초과 회수 불가.**
- `strike`/`ftPerUSD`가 mint 시점 값으로 고정 → invest↔divest 왕복 안전.
- 전 상태변경 함수 `nonReentrant`(transient) + CEI. pFT.mint(receiver hook)은 상태 갱신 후 마지막 호출.

### pFT (ERC721)
- 포지션 struct: `{token, amount, ft, ft_bought, withdrawn, burned, strike, amountRemaining, ftPerUSD}`.
- `divest`(burned++)/`withdrawFT`(withdrawn++) 모두 ft·amountRemaining 상한 검사 후 감소. ft==0이면 burn + amountRemaining dust 0 처리.

### ftYieldWrapper
- 담보 1:1 share 모델(비례 share 아님) → first-depositor inflation 없음.
- `withdraw`/`withdrawUnderlying`가 전략을 순서대로 drain. `deployed`/`deployedToStrategy` clamp 회계.
- **CircuitBreaker는 fail-open** (`try…catch{}`) — 코드 주석에 의도 명시.

### CircuitBreaker
- ERC-7265 기반 이중 버퍼: main(TVL 5% 시간복원) + elastic(예치 추적).
- 산술은 건전(퍼징 30k 콜에서 예산 초과 승인 없음). 단 elastic이 예치액과 1:1 증가(→ findings FT-01).

### FlyingTulipOracle
- Aave 가격 + min/max 경계 + 고정 `ftPerUSD`(=10). divest가 저장값 사용 → 왕복 안전.

### pFTMarketplace
- 직접 리스팅 매매(`buy`) + EIP-712 서명 오퍼(`acceptBuyOffer`) + Permit2 결제.
- 자금 흐름 보존: 구매자 = price+takerFee, 판매자 = price−makerFee, fee = 합. marketplace는 자금/NFT 미보유.

### FT (OFT)
- LayerZero OFT + pause `_update` 게이팅(configurator/endpoint 예외) + 커스텀 permit(ECDSA + ERC-1271).
- 크로스체인 mint/burn은 LZ 감사 베이스 상속(커스텀 표면 = pause + permit만, 둘 다 안전).

### 전략 (Spark ERC4626 / Aave)
- 둘 다 값 보존적. Aave = aToken 1:1. Spark = ERC4626 share 변환(반올림 내림, 프로토콜 유리).
- `claimYield`는 `valueOfCapital ≥ totalSupply` 가드 → 원금 아래로 안 떨어짐.

---

## 3. 실증적으로 확인된 안전 불변식 (52 tests)

- **무손익:** 사용자 총 회수 ≤ 총 예치 (오라클 pump/dump·yield 하에서도).
- **솔번시:** vault 회수가치 ≥ collateralSupply (다중 전략·유동성 변동 포함).
- **전역 정합:** `collateralSupply == wrapper.totalSupply`, `Σ 포지션.ft == ftAllocated`, `FT.balanceOf(PutManager) == ftOfferingSupply`, `deployed == Σ deployedToStrategy`.
- **backing:** `collateralSupply ≥ Σ amountRemaining + capitalDivesting` (초과분은 알려진 PM-01 dust, 프로토콜 유리 방향).
- **가격 수학:** 전 파라미터에서 `collateralFromFT(ftFromCollateral(x)) ≤ x`, 청크 분할 무이익, FT 인플레 없음.
- **Marketplace:** 자금/NFT 보존, 오퍼 취소·replay·서명자·비적격 NFT 거부.
- **CB:** rate-limit 예산 초과 승인 없음.
- **FT OFT:** pause 게이팅·permit·burn·공급 보존 정상.

---

## 4. 재현 방법

```bash
cd ../fuzz
forge test                              # 전체 (52 tests)
forge test --match-contract FTInvariant   # 코어 회계
forge test --match-contract CBInvariant   # CircuitBreaker + FT-01/02 PoC
forge test --match-contract SparkInflationPoC -vv   # FT-05 PoC
forge test --match-contract PricingFuzz --fuzz-runs 50000
```

- 의존성: OpenZeppelin v5.3.0 (배포 impl과 일치; v5.5.0은 `__UUPSUpgradeable_init` 제거), solc 0.8.30, evm cancun, via_ir.
- LayerZero 소스는 `../_libs`에서 컴파일 (`@layerzerolabs/=lib-lz/at_layerzerolabs/`).

### 환경 함정 (기록)
- **foundry:** 인자로 넣은 인라인 외부호출(`mkt.getCurrentPutHash(id)`)이 앞선 `vm.prank`/`vm.expectRevert`를 소비 → 로컬 변수로 선계산.
- **macOS 대소문자 미구분 FS:** `IftPut.sol` ↔ `IftPUT.sol` 충돌 → marketplace용을 `IPutView.sol`로 분리.
- **하네스 함정:** 핸들러가 `onERC721Received` 미구현이면 모든 invest가 조용히 revert → 불변식이 빈 시스템에서 무의미하게 통과. **활동 카운터 + directed 테스트로 하네스가 실제 상태를 변경하는지 반드시 확인.**

---

*발견 항목과 판단 근거는 [findings.md](findings.md) 참조.*
