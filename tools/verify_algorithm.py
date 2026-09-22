#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
算法验证镜像（reference mirror）。

这不是应用的一部分，是开发期的验证工具。它把 lib/core/store.dart 里的
核心算法逐行照抄成 Python，然后跑跟 test/logic_test.dart 同一批断言。

目的：在 Flutter 环境就绪之前，先用能跑的 Python 证明**算法语义**是对的。
等 Flutter 装好、跑 dart 版测试时，两边结论必须一致；不一致就说明
Python 镜像和 Dart 实现发生了偏离，需要查。

注意：它验证的是算法，不是 Dart 语法。Dart 能不能编译仍要靠 flutter analyze。
运行：python tools/verify_algorithm.py
"""

import math
import random
import sys

# --------------------------------------------------------------------- 模型


class Person:
    """对应 lib/core/models.dart 的 Person。"""

    def __init__(self, name, weight=1.0, note=""):
        self.name = name
        self.weight = weight
        self.note = note

    @property
    def safe_weight(self):
        # 对应 Dart: (weight.isFinite && weight > 0) ? weight : 0.0
        w = self.weight
        if not math.isfinite(w) or w <= 0:
            return 0.0
        return w


# --------------------------------------------------------------- 权重抽取


def weighted_pick(candidates, rng):
    """对应 store.dart 的 Top-level weightedPick。"""
    if not candidates:
        return None

    total = 0.0
    for p in candidates:
        total += p.safe_weight

    if total <= 0:
        # 全员 0 权重 -> 等概率兜底，不崩溃
        return candidates[rng.randrange(len(candidates))]

    r = rng.random() * total
    last_positive = None
    for p in candidates:
        w = p.safe_weight
        if w <= 0:
            continue  # 必须显式跳过：否则 r 恰好为 0 时会抽出 0 权重的人
        last_positive = p
        r -= w
        if r <= 0:
            return p
    return last_positive if last_positive is not None else candidates[-1]


# ------------------------------------------------------------- 池子推导


def derive_pool_names(drawn, people):
    """对应 store.dart 的 derivePoolNames。"""
    remaining = {}
    for p in people:
        remaining[p.name] = remaining.get(p.name, 0) + 1

    for name in drawn:
        c = remaining.get(name, 0)
        if c > 0:
            remaining[name] = c - 1

    pool = []
    for p in people:
        c = remaining.get(p.name, 0)
        if c > 0:
            pool.append(p.name)
            remaining[p.name] = c - 1
    return pool


# ------------------------------------------------------------- DataStore


class Store:
    """对应 store.dart 的 DataStore，只保留抽取相关部分。"""

    def __init__(self, seed=0):
        self.drawn = {}
        self.history = []
        self.rng = random.Random(seed)

    def eligible(self, people):
        pos = [p for p in people if p.safe_weight > 0]
        return pos if pos else list(people)

    def eligible_count(self, people):
        return len(self.eligible(people))

    def pool_of(self, lid, people):
        return derive_pool_names(self.drawn.get(lid, []), self.eligible(people))

    def remaining(self, lid, people):
        return len(self.pool_of(lid, people))

    def drawn_count(self, lid, people):
        return self.eligible_count(people) - self.remaining(lid, people)

    def prune_drawn(self, lid, people):
        d = self.drawn.get(lid)
        if not d:
            return
        allowed = {}
        for p in people:
            allowed[p.name] = allowed.get(p.name, 0) + 1
        used = {}
        kept = []
        for name in d:
            mx = allowed.get(name, 0)
            have = used.get(name, 0)
            if have < mx:
                kept.append(name)
                used[name] = have + 1
        self.drawn[lid] = kept

    def draw(self, lid, people, mode, count, allow_dup):
        budget = max(1, count)
        picked = []

        if mode == "noRepeat":
            eligible = self.eligible(people)
            by_name = {}
            for p in eligible:
                by_name.setdefault(p.name, p)
            candidates = []
            for n in derive_pool_names(self.drawn.get(lid, []), eligible):
                p = by_name.get(n)
                candidates.append(p if p is not None else Person(n))

            for _ in range(min(budget, len(candidates))):
                chosen = weighted_pick(candidates, self.rng)
                if chosen is None:
                    break
                picked.append(chosen.name)
                candidates.remove(chosen)  # Person 无 __eq__ -> 按身份删除，等同 Dart

            if picked:
                self.drawn.setdefault(lid, []).extend(picked)
        else:
            source = self.eligible(people)
            if allow_dup:
                for _ in range(budget):
                    c = weighted_pick(source, self.rng)
                    if c is None:
                        break
                    picked.append(c.name)
            else:
                working = list(source)
                for _ in range(min(budget, len(working))):
                    c = weighted_pick(working, self.rng)
                    if c is None:
                        break
                    picked.append(c.name)
                    working.remove(c)

        rem = self.remaining(lid, people)
        total = self.eligible_count(people)
        finished = mode == "noRepeat" and rem == 0 and total > 0

        if picked:
            self.history.insert(0, (lid, mode, list(picked)))

        return {
            "names": picked,
            "remaining": rem,
            "list_size": total,
            "round_finished": finished,
        }


# ------------------------------------------------------------ 迷你测试框架

PASS = 0
FAIL = 0
FAILED_LABELS = []


def check(label, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILED_LABELS.append(label)
        print("  [FAIL] %s" % label)


def section(title):
    print("\n== %s ==" % title)


def people_of(names):
    return [Person(n) for n in names]


# ------------------------------------------------------------------ 用例


def main():
    section("derivePoolNames")

    check("没人抽走时池子=完整名单",
          derive_pool_names([], people_of(["a", "b", "c"])) == ["a", "b", "c"])
    check("抽走的人不在池子里，顺序保持",
          derive_pool_names(["b"], people_of(["a", "b", "c"])) == ["a", "c"])
    check("抽完一轮池子为空",
          derive_pool_names(["a", "b", "c"], people_of(["a", "b", "c"])) == [])
    check("过期的 drawn 条目被忽略",
          derive_pool_names(["b"], people_of(["a", "c"])) == ["a", "c"])
    check("完全不存在的 drawn 条目被忽略",
          derive_pool_names(["x", "y"], people_of(["a", "b"])) == ["a", "b"])
    check("重名：0 个抽走",
          derive_pool_names([], people_of(["a", "a", "a"])) == ["a", "a", "a"])
    check("重名：1 个抽走",
          derive_pool_names(["a"], people_of(["a", "a", "a"])) == ["a", "a"])
    check("重名：2 个抽走",
          derive_pool_names(["a", "a"], people_of(["a", "a", "a"])) == ["a"])
    check("重名：全部抽走",
          derive_pool_names(["a", "a", "a"], people_of(["a", "a", "a"])) == [])

    check("【回归】加人不会让已抽走的人复活",
          derive_pool_names(["p1", "p2"],
                            people_of(["p1", "p2", "p3", "p4", "p5", "p6"]))
          == ["p3", "p4", "p5", "p6"])

    section("weightedPick")

    c1 = [Person("a", 0), Person("b", 1)]
    rng = random.Random(42)
    check("0 权重永远抽不到（500 次）",
          all(weighted_pick(c1, rng).name == "b" for _ in range(500)))

    # 专门验证边界：把随机数强行钉在 0.0，看会不会抽出 0 权重的人
    class ZeroRng:
        def random(self):
            return 0.0

        def randrange(self, n):
            return 0

    check("【回归】随机数恰好为 0.0 时也不会抽出 0 权重的人",
          weighted_pick(c1, ZeroRng()).name == "b")

    c2 = [Person("a", 0), Person("b", 0)]
    rng2 = random.Random(1)
    seen = set()
    for _ in range(300):
        seen.add(weighted_pick(c2, rng2).name)
    check("全员 0 权重 -> 等概率兜底而不是崩溃", seen == {"a", "b"})

    c3 = [Person("low", 1), Person("high", 9)]
    rng3 = random.Random(7)
    high = sum(1 for _ in range(2000) if weighted_pick(c3, rng3).name == "high")
    check("高权重被抽中次数明显更多 (实际 %d, 期望约 1800)" % high, high > 1500)

    check("空列表返回 None", weighted_pick([], random.Random(1)) is None)

    check("Infinity 权重被当成 0",
          Person("x", float("inf")).safe_weight == 0.0)
    check("NaN 权重被当成 0",
          Person("x", float("nan")).safe_weight == 0.0)
    check("负数权重被当成 0",
          Person("x", -5).safe_weight == 0.0)

    section("不重复模式")

    P5 = people_of(["p1", "p2", "p3", "p4", "p5"])

    s = Store(1)
    picked = []
    for _ in range(5):
        picked.extend(s.draw("L", P5, "noRepeat", 1, False)["names"])
    check("抽满一轮 5 次共 5 个人", len(picked) == 5)
    check("一轮内互不相同", len(set(picked)) == 5)
    check("抽完后剩余 0", s.remaining("L", P5) == 0)
    after = s.draw("L", P5, "noRepeat", 1, False)
    check("抽完后再抽返回空", after["names"] == [])
    check("抽完后 round_finished=True", after["round_finished"] is True)

    s = Store(2)
    r = s.draw("L", P5, "noRepeat", 3, False)
    check("一次抽 3 个 -> 3 个", len(r["names"]) == 3)
    check("一次抽 3 个互不相同", len(set(r["names"])) == 3)
    check("一次抽 3 个后剩余 2", s.remaining("L", P5) == 2)
    check("drawn_count = 3", s.drawn_count("L", P5) == 3)

    s = Store(3)
    r = s.draw("L", P5, "noRepeat", 99, False)
    check("要抽 99 个但只有 5 个 -> 抽 5 个", len(r["names"]) == 5)
    check("round_finished=True", r["round_finished"] is True)

    s = Store(4)
    s.draw("L", P5, "noRepeat", 2, False)
    already = list(s.drawn["L"])
    check("抽 2 个后剩余 3", s.remaining("L", P5) == 3)
    P6 = people_of(["p1", "p2", "p3", "p4", "p5", "p6"])
    s.prune_drawn("L", P6)
    check("【回归】加 p6 后剩余 4（不是 6）", s.remaining("L", P6) == 4)
    check("【回归】加人后 drawn_count 仍是 2", s.drawn_count("L", P6) == 2)
    pool = s.pool_of("L", P6)
    check("【回归】已抽走的人没有复活",
          all(n not in pool for n in already))
    check("新加的 p6 进了池子", "p6" in pool)

    s = Store(5)
    r = s.draw("L", P5, "noRepeat", 1, False)
    drawn_name = r["names"][0]
    full = ["p1", "p2", "p3", "p4", "p5"]
    # 刻意删掉一个「没被抽中」的人：新名单 4 人，而且包含刚被抽中的那个
    victim = next(n for n in full if n != drawn_name)
    narrowed = [n for n in full if n != victim]
    s.prune_drawn("L", people_of(narrowed))
    check("被删的人确实不在新名单里", victim not in narrowed)
    check("刚被抽中的人还在新名单里", drawn_name in narrowed)
    check("删掉一个没抽中的人后剩余 3", s.remaining("L", people_of(narrowed)) == 3)
    check("drawn_count 仍是 1", s.drawn_count("L", people_of(narrowed)) == 1)
    check("已抽走的人仍不在池子",
          drawn_name not in s.pool_of("L", people_of(narrowed)))

    s = Store(6)
    s.draw("L", P5, "noRepeat", 1, False)
    # 把池子清空（模拟抽完），再验证重置
    s.draw("L", P5, "noRepeat", 99, False)
    check("抽完后 remaining=0", s.remaining("L", P5) == 0)
    s.drawn["L"] = []
    check("resetRound 后 remaining=5", s.remaining("L", P5) == 5)
    check("resetRound 后 drawn_count=0", s.drawn_count("L", P5) == 0)

    section("可重复模式")

    s = Store(7)
    r = s.draw("L", P5, "repeat", 5, False)
    check("一次抽 5 个默认互不相同", len(set(r["names"])) == 5)
    check("可重复模式不动池子", s.remaining("L", P5) == 5)

    s = Store(8)
    r = s.draw("L", P5, "repeat", 40, True)
    check("允许重复时能抽到同一个人（抽 40 次）", len(set(r["names"])) < 40)
    check("允许重复时只可能是名单里的人",
          set(r["names"]).issubset({"p1", "p2", "p3", "p4", "p5"}))
    check("允许重复时池子不受影响", s.remaining("L", P5) == 5)

    section("权重 0 的语义")

    s = Store(9)
    PW = [Person("never", 0), Person("always", 5)]
    check("eligible_count 只算 1 个", s.eligible_count(PW) == 1)
    check("池子里只有 always", s.pool_of("L", PW) == ["always"])
    r = s.draw("L", PW, "noRepeat", 2, False)
    check("抽 2 个只会得到 always", r["names"] == ["always"])
    check("【回归】0 权重的人不会把这一轮永远卡住", r["round_finished"] is True)

    s = Store(10)
    PW2 = [Person("a", 0), Person("b", 0), Person("c", 1)]
    r = s.draw("L", PW2, "noRepeat", 3, False)
    check("部分 0 权重时只抽有权的那些", r["names"] == ["c"])

    section("历史记录")

    s = Store(11)
    s.draw("L", P5, "noRepeat", 2, False)
    check("抽取写入历史", len(s.history) == 1)
    check("历史内容长度正确", len(s.history[0][2]) == 2)

    # ------------------------------------------------------------- 汇总
    print("\n" + "=" * 52)
    print("通过 %d 项，失败 %d 项" % (PASS, FAIL))
    if FAILED_LABELS:
        print("\n失败清单：")
        for label in FAILED_LABELS:
            print("  - " + label)
    print("=" * 52)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
