---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'Gradual traffic migration'
pubDate: 2026-03-16
description: 'Gradual traffic migration'
author: 'tyzerrr'
---

# Our service's API migration with Magician
My team is building a microservice that handles all payment transactions on Mercari.  
We need to handle multiple payment methods like Credit Card 3DS, Apple pay, Famipay and so on.  
Also, we have been working on building a new API that we call v2 (the previous API is called v1).  
For now, v1 and v2 are running at the same time, but we need to move to v2 gradually.  
V1 implementation is like [State Machine](https://www.geeksforgeeks.org/system-design/state-design-pattern/), but v2 is implemented with Magician, our internal workflow tool.  
Magician is inspired by [Cadence](https://github.com/cadence-workflow/cadence), developed by Uber, and it handles retry, timeout, and recoverable errors.  
By using Magician, we only need to care about essential business logic, and improve service reliability.  
Below is the sample code using Magician.  

```go
package api

import (
    "context"
    "fmt"

    "github.com/payemnt/some/workflow"
)


func (p *PaymentService) UseCreditCard(ctx context.Context, req *UseCreditCardRequest) (*UseCreditCardResponse, error) {
    // api call with Magician
    // Magician will handle retry, timeout, completable errors, so we only need to care about essential business logic.
    // workflow.creditCardWorkflow is actual implementation, req.UserID and req.Amount are parameters for workflow.
    // What we need to do is just wrapping our actual implementation with Magician.Workflow.
    if err := p.magician.Workflow(workflow.creditCardWorkflow, req.UserID, req.Amount).ExecuteWait(ctx); err != nil {
        return &UseCreditCardResponse{
            Success: false,
            Message: fmt.Sprintf("failed to use credit card: %v", err),
        }, err
    }
    return &UseCreditCardResponse{
        Success: true,
        Message: "credit card used successfully",
    }, nil
}

```
As you can see, the v2 implementation is completely dependent on Magician, and thus differs from v1.  


# My task and difficulties
At first, my task is traffic migration from v1 to v2 for only a specific payment resource. (Since this is my personal tech blog, I can't share all the details with you about my task.)  
A payment transaction consists of many steps: **Create**, **Authorize**, **Capture**, and each step calls a different API of our service.  
To avoid compromising the user experience, each consecutive step must be handled by the same versioned API.  
Also, it is high-risk to move all traffic from v1 to v2 at once, so we need to migrate traffic gradually with Canary deployment.  

Our service uses Kubernetes, and we decided to control the percentage of traffic to the v2 API by environment variables defined in ConfigMap.
As usual, we use Canary deployment, however we have a problem.
Old pods don't have the routing logic, so just updating the ConfigMap and deploying new pods is not enough.

# Solution
Initially, everybody comes up with **Rolling Update**, but it has the same problem.  
During a rolling update, some pods still run the old version, so we can't achieve the goal: each step must be handled by the same versioned API.  

The solution has two steps.  
- **Deploy new pods with a 0 value for the v2-routing rate using a Canary deployment strategy**.
- Update the ConfigMap with the v2-routing rate.

The first step is the most important.  
We deploy the new pods, but the v2-routing rate is zero, so all traffic is routed to v1.  

Then update the ConfigMap to set the routing rate to a higher value.

