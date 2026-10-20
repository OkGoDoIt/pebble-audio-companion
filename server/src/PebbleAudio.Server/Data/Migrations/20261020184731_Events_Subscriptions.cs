using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace PebbleAudio.Server.Data.Migrations
{
    /// <inheritdoc />
    public partial class Events_Subscriptions : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "EventSubscriptions",
                columns: table => new
                {
                    Id = table.Column<string>(type: "character varying(40)", maxLength: 40, nullable: false),
                    UserId = table.Column<Guid>(type: "uuid", nullable: false),
                    EventName = table.Column<string>(type: "text", nullable: false),
                    ArgumentsJson = table.Column<string>(type: "text", nullable: false),
                    CallbackUrl = table.Column<string>(type: "text", nullable: false),
                    ProtectedSecret = table.Column<string>(type: "text", nullable: false),
                    ProtectedPreviousSecret = table.Column<string>(type: "text", nullable: true),
                    PreviousSecretUntil = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    ClientName = table.Column<string>(type: "text", nullable: false),
                    GrantId = table.Column<Guid>(type: "uuid", nullable: true),
                    ApiTokenId = table.Column<Guid>(type: "uuid", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    RenewedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    VerifiedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    ExpiresAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    LastDeliveredAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    LastError = table.Column<string>(type: "text", nullable: true),
                    LastErrorAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EventSubscriptions", x => x.Id);
                    table.ForeignKey(
                        name: "FK_EventSubscriptions_ApiTokens_ApiTokenId",
                        column: x => x.ApiTokenId,
                        principalTable: "ApiTokens",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_EventSubscriptions_AspNetUsers_UserId",
                        column: x => x.UserId,
                        principalTable: "AspNetUsers",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                    table.ForeignKey(
                        name: "FK_EventSubscriptions_OAuthGrants_GrantId",
                        column: x => x.GrantId,
                        principalTable: "OAuthGrants",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_EventSubscriptions_ApiTokenId",
                table: "EventSubscriptions",
                column: "ApiTokenId");

            migrationBuilder.CreateIndex(
                name: "IX_EventSubscriptions_GrantId",
                table: "EventSubscriptions",
                column: "GrantId");

            migrationBuilder.CreateIndex(
                name: "IX_EventSubscriptions_UserId_EventName",
                table: "EventSubscriptions",
                columns: new[] { "UserId", "EventName" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "EventSubscriptions");
        }
    }
}
