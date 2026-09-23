# -*- coding: utf-8 -*-
# _cvm_price.py —— 当前实例规格 + 升配候选询价（ResetInstancesType）
import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvm_tat as T


def main() -> int:
    from tencentcloud.cvm.v20170312 import models
    c = T._cvm()
    # 1) 当前规格
    req = models.DescribeInstancesRequest()
    req.from_json_string(json.dumps({"InstanceIds": [T.INSTANCE]}))
    resp = c.DescribeInstances(req)
    inst = resp.InstanceSet[0]
    print("CURRENT: id=%s type=%s cpu=%s mem=%s state=%s charge=%s" % (
        inst.InstanceId, inst.InstanceType, inst.CPU, inst.Memory,
        inst.InstanceState, inst.InstanceChargeType))
    # 2) 候选规格询价（同族 S5 升配）
    for t in ["S5.LARGE8", "S5.2XLARGE16", "S5.4XLARGE32", "S5.8XLARGE64"]:
        try:
            req2 = models.InquiryPriceResetInstancesTypeRequest()
            req2.from_json_string(json.dumps({"InstanceIds": [T.INSTANCE], "InstanceType": t}))
            r2 = c.InquiryPriceResetInstancesType(req2)
            price = r2.Price
            print("%s -> %s" % (t, price.to_json_string() if price else "(no price)"))
        except Exception as e:  # noqa
            print("%s -> ERROR %s" % (t, str(e)[:200]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
