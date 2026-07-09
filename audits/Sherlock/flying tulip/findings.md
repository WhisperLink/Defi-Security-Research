# Flying Tulip (ftPUT) — 발견 항목 + 판단 근거

> **최종 판정:** 비특권 공격자가 현 프로덕션에서 자금을 잃게 만드는 **Critical / High / Medium 취약점 없음.**
> 아래 5개(FT-01~05)는 전부 **informational** — 손실 도달성이 없거나(별도 drain 전제), 신뢰 롤 소관이거나,
> 실제 vault가 무력화. **바운티 제출용이 아니라 팀 informational 공유용.**

---

## 판단 프레임

바운티에서 Medium 이상이 되려면: **비특권 공격자 + 신뢰 롤 오작동에 기대지 않고 + 실제 배포 상태에서 자금 손실(또는 장기 동결) + 동작 PoC.**
5개 항목이 각각 어디서 이 문턱을 못 넘는지 명시했다.

| ID | 제목 | 실제 손실 PoC? | 제출 불가 사유 | 등급 |
|---|---|---|---|---|
| FT-01 | CB elastic 버퍼 한도 증폭 (21x) | ❌ | 별도 drain + 자본 잠금 전제, 플래시론 불가. elastic은 ERC-7265 설계상 의도 | Info |
| FT-02 | CB fail-open + 버퍼 롤백 | ❌ | 트리거(amount>preTvl)가 divest로 도달 불가. fail-open은 인터페이스에 명시된 의도 | Info |
| FT-03 | 소형 3풀 CB 미설정 (`circuitBreaker=0`) | ❌ | strategyManager(신뢰 롤) 소관 → 규정상 informational | Info |
| FT-04 | SparkSavingsStrategy 스코프 불일치 | ❌ | 버그 아님 (범위 문의) | Info |
| FT-05 | Spark deposit 슬리피지/minShares 부재 (ERC4626 inflation) | ✅ (fresh vault) | 실제 vault가 성숙 + 내부회계 → 도달 불가 | Info |

---

## FT-01 — CircuitBreaker elastic 버퍼가 인출 한도를 예치액만큼 증폭

**대상:** `CircuitBreaker.recordInflow` (`elasticBuffer += amount`), `ftYieldWrapper.deposit`
**입증:** `CBInvariant.t.sol::test_A_elasticInflatesRateLimit`

CB 실효 한도 = `5%·TVL + (최근 2h 예치액)`. TVL 규모를 예치하면 한도가 5% → 105%로 **21배** 증폭(실측). 팀의 "1시간 대응" 가정을 약화.

**판단 — 왜 Info인가:** 단독 손실 0. elastic 용량을 drain에 쓰려면 **동일 담보를 잠가야** 하고 되찾으려면 또 용량 필요 → 같은 tx 내 `invest→drain→divest 회수`가 rate-limit에 다시 걸려 **플래시론 불가**. 증폭기이지 자금 생성 아님. + elastic 버퍼는 ERC-7265의 의도된 deposit-tracking 동작.
**패치:** `available` 계산 시 elastic 기여를 `cap * K`로 클램프, 또는 절대 per-window 상한 도입.

---

## FT-02 — CircuitBreaker fail-open + 언더플로우 시 버퍼 롤백

**대상:** `ftYieldWrapper.withdraw:494 / withdrawUnderlying:595` (`} catch {}`), `CircuitBreaker.checkAndRecordOutflow:154` (`preTvl - amount`)
**입증:** `CBInvariant.t.sol::test_B_failOpen_bufferRollback` (버퍼 롤백 확인), `test_B2_wrapperInputsAreSafe`

wrapper가 CB revert를 `catch{}`로 삼킴(fail-open). CB는 버퍼 차감 후 `emit Outflow(…, preTvl - amount)`에서 `amount > preTvl`이면 언더플로우 revert → 차감이 롤백 → rate-limit 미갱신. 해당 대역 반복 인출로 limiter 무력화.

**판단 — 왜 Info:** `amount ≤ collateralSupply ≈ preTvl`이라 divest 경로로 **언더플로우 브랜치 도달 불가**(test_B2). 현재 트리거 불가. fail-open도 인터페이스 주석에 "designed for fail-open"으로 명시된 의도. 잠재 결함일 뿐.
**패치:** (1) `postTvl = amount > preTvl ? 0 : preTvl - amount` 로 언더플로우 제거(무해, 반드시). (2) rate-limit 판정은 fail-closed로.

---

## FT-03 — 프로덕션 3개 풀의 wrapper에 CircuitBreaker 미연결

**대상:** `ftYieldWrapper.setCircuitBreaker` (0 허용), 라이브 상태
**입증:** 온체인 조회 — USDS/USDtb/USDe wrapper `circuitBreaker() == 0x0`

세 풀은 rate-limit이 전무. 별도 drain 시 CB 감속 없이 즉시 전액 인출 가능. FT-02의 fail-open과 결합하면 CB 부재가 은폐.

**판단 — 왜 Info:** CB 설정은 strategyManager(**완전 신뢰 롤**) 소관 → 바운티 규정상 informational. 소형 풀(~$74k 합계). 손실 프리미티브 없음.
**권고:** strategyManager가 세 wrapper에 `setCircuitBreaker(CB)` 호출.

---

## FT-04 — SparkSavingsStrategy가 감사 파일 목록 밖 (스코프 문의)

**대상:** 배포 전략 (USDC/WETH/USDT 대형 3풀, ~$49M)
**입증:** 온체인 — strategy(0)이 `SparkSavingsStrategy`(스코프엔 `AaveStrategy.sol`만 명시)

자금 대부분을 운용하는 코드가 감사 파일 목록에 없음 → 커버리지/판정 리스크. (버그 아님)

**권고:** 판정팀에 스코프 포함 여부 문의. 포함이면 ERC4626 연동부(share 반올림·유동성·in-kind 인출) 집중 검토.

---

## FT-05 — SparkSavingsStrategy.deposit에 슬리피지/minShares 보호 없음 (ERC4626 inflation)

**대상:** `SparkSavingsStrategy.deposit` (`vault.deposit(amount, this)` — 받는 share 검증 없음)
**입증:** `SparkInflationPoC.t.sol` — fresh vault: 1M 예치 → 회수 990k(**10k 손실**) / 성숙 vault($300M): 1 wei
+ end-to-end 퍼저(`SparkInvariant`)가 `invest → 기부 → deployIdle` 시퀀스를 자율 발견해 ~8,961 USDC 부족 재현

vault share 가격이 부풀려진 상태에서 대규모 예치 시 반올림으로 프로토콜이 손실. 잘 알려진 ERC4626 donation/inflation 표면.

**판단 — 왜 Info (2겹으로 차단):**
1. **현 3개 vault 모두 성숙** ($307M/$170M+/$455M) → share 가격 조작에 수억 달러 필요, 경제적 불가능.
2. **모두 내부 회계** (`totalAssets ≫ 자체 토큰 잔액`: spUSDC 307M 보고 vs 10M USDC 보유) → **토큰 기부로 share 가격 안 움직임** → donation 공격 원천 봉쇄. (온체인 확인)
3. 6개 wrapper 모두 전략 1개·pending 없음 → 저유동성 전략도 없음.

→ **현 상태 도달 불가.** 리스크는 미래에 성숙하지 않은/naive ERC4626 vault를 온보딩할 경우에만.
**패치:** 예치 직후 `convertToAssets(shares) + tolerance ≥ amount` 가드 추가; 신규 vault 온보딩 시 충분한 TVL 확인.

---

## 최종 판정 & 판단 근거

**제출 가능한 취약점 없음.** 5개 항목의 공통 결격 사유는 동일 — **실제 배포 상태에서 비특권 공격자가 도달 가능한 자금 손실 경로의 부재.** 정적 정독과 52개 동적 테스트가 코어 회계·가격 수학·CB·마켓·OFT·전략 전 계층의 견고함을 실증.

**판정을 뒤집을 조건:**
- FT-05 → 비공개 `deployments.toml`에 **저유동성/naive ERC4626 vault**가 전략 대상으로 존재 (판정 시 참조 명시됨).
- FT-01/02/03 → **별도의 실제 drain 프리미티브**를 발견 시, CB 우회 논거로 묶어 등급을 TVL(Critical)로 격상.

**권고:** 5개 항목은 바운티 제출(각 $250 예치금 위험) 대신 **팀 informational 공유**가 적절. 특히 FT-05(전략 슬리피지 가드)와 FT-04(스코프 명확화)는 팀에 유용.
