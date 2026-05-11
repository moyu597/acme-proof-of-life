using System.Data;
using Dapper;
using Microsoft.AspNetCore.Mvc;

namespace AcmeStub.Controllers;

[ApiController]
[Route("api/orders")]
public sealed class OrdersController : ControllerBase
{
    private readonly IDbConnection _db;

    public OrdersController(IDbConnection db) => _db = db;

    public sealed record CreateOrderRequest(int CustomerId, decimal Amount);
    public sealed record Order(int Id, int CustomerId, decimal Amount, DateTime CreatedAt);

    [HttpGet]
    public async Task<IEnumerable<Order>> Recent() =>
        await _db.QueryAsync<Order>(@"
            SELECT TOP 10 id AS Id, customer_id AS CustomerId, amount AS Amount, created_at AS CreatedAt
            FROM dbo.orders ORDER BY id DESC");

    [HttpPost]
    public async Task<ActionResult<Order>> Create([FromBody] CreateOrderRequest req)
    {
        if (req.Amount <= 0) return BadRequest("amount must be positive");

        var inserted = await _db.QuerySingleAsync<Order>(@"
            INSERT INTO dbo.orders (customer_id, amount)
            OUTPUT inserted.id AS Id, inserted.customer_id AS CustomerId,
                   inserted.amount AS Amount, inserted.created_at AS CreatedAt
            VALUES (@CustomerId, @Amount);",
            new { req.CustomerId, req.Amount });

        return CreatedAtAction(nameof(Recent), new { id = inserted.Id }, inserted);
    }
}
