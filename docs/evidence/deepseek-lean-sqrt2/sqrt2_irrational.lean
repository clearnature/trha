-- Lean 4 (4.34.1, core only, no mathlib) formalization of the irrationality of √2.
-- What is proved: ∀ q : Nat, q ≠ 0 → ¬ ∃ p : Nat, p * p = 2 * (q * q)
-- i.e. no rational p/q (q ≠ 0) satisfies (p/q)^2 = 2, so √2 ∉ ℚ.  Proof: parity + strong induction (descent).
def Even (n : Nat) : Prop := ∃ k, n = 2 * k

theorem even_iff_mod_two (n : Nat) : Even n ↔ n % 2 = 0 := by
  constructor
  · rintro ⟨k, rfl⟩
    omega
  · intro h
    exact ⟨n / 2, by omega⟩

theorem even_of_mul_self_even (n : Nat) (h : (n * n) % 2 = 0) : n % 2 = 0 := by
  rcases Nat.mod_two_eq_zero_or_one n with h0 | h1
  · exact h0
  · rw [Nat.mul_mod, h1] at h
    exact absurd h (by decide)

theorem sq_two_mul (k : Nat) : (2 * k) * (2 * k) = 4 * (k * k) := by
  simp [Nat.mul_assoc, Nat.mul_comm, Nat.mul_left_comm]

example (q : Nat) (hm : q = 2 * 0) (hq : q ≠ 0) : False := by omega

theorem no_nat_solution : ∀ q : Nat, ¬ ∃ p : Nat, q ≠ 0 ∧ p * p = 2 * (q * q) := by
  intro q
  induction q using Nat.strongRecOn with
  | ind q ih =>
    rintro ⟨p, hq, hp⟩
    have hp2 : p % 2 = 0 := by
      apply even_of_mul_self_even
      rw [hp]
      omega
    obtain ⟨k, hk⟩ := (even_iff_mod_two p).mpr hp2
    have h1 : q * q = 2 * (k * k) := by
      rw [hk] at hp
      rw [sq_two_mul] at hp
      omega
    have hq2 : q % 2 = 0 := by
      apply even_of_mul_self_even
      rw [h1]
      omega
    obtain ⟨m, hm⟩ := (even_iff_mod_two q).mpr hq2
    have h2 : k * k = 2 * (m * m) := by
      rw [hm] at h1
      rw [sq_two_mul] at h1
      omega
    have hm0 : m ≠ 0 := by omega
    have hmlt : m < q := by omega
    exact ih m hmlt ⟨k, hm0, h2⟩
