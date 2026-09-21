namespace RPA.CPH.NonSubsidy.Domain.Migrations
{
    using System;
    using System.Data.Entity.Migrations;
    
    public partial class AddLandParcelInactivate : DbMigration
    {
        public override void Up()
        {
            AddColumn("CPH.LandParcels", "Active", c => c.Boolean(nullable: false));
        }
        
        public override void Down()
        {
            DropColumn("CPH.LandParcels", "Active");
        }
    }
}
